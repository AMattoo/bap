open Core_kernel.Std
open Bap_plugins.Std
open Bap.Std
open Or_error
open Format
open Options

module C = Frontc

module Program(Conf : Options.Provider) = struct
  open Conf

  let find_roots arch mem : addr list  =
    if options.bw_disable then []
    else
      let module BW = Byteweight.Bytes in
      let path = options.sigfile in
      match Signatures.load ?path ~mode:"bytes" arch with
      | None ->
        eprintf "No signatures found@.Please, use `bap-byteweight update' \
                 to get the latest available signatures.@.%!";
        []
      | Some data ->
        let bw = Binable.of_string (module BW) data in
        let length = options.bw_length in
        let threshold = options.bw_threshold in
        BW.find bw ~length ~threshold mem

  let pp_addr f fn = Addr.pp f (Block.addr @@ Symtab.entry_of_fn fn)
  let pp_name f fn = fprintf f "%-30s" (Symtab.name_of_fn fn)

  let extract_symbols option ~f =
    match option with
    | None -> []
    | Some value -> f value

  let run project =
    let library = options.load_path in
    let project = options.passes |> List.fold ~init:project
                    ~f:(Project.run_pass_exn ~library) in
    Option.iter options.emit_ida_script (fun dst ->
        Out_channel.write_all dst
          ~data:(Idapy.extract_script (Project.memory project)));

    let module Target =
      (val target_of_arch @@ Project.arch project) in
    let module Env = struct
      let options = options
      let project = project
      module Target = Target
    end in
    let module Printing = Printing.Make(Env) in
    let module Helpers = Helpers.Make(Env) in
    let open Printing in

    let (dump : insn_format list) =
      List.filter_map options.output_dump ~f:(function
          | #insn_format as fmt -> Some fmt
          | `with_bir ->
            List.iter options.emit_attr ~f:Text_tags.print_attr;
            Text_tags.with_mode std_formatter `Attr ~f:(fun () ->
                printf "%a" Program.pp (Project.program project));
            None) in

    let syms = Project.symbols project in

    let pp_size f fn =
      let mem = Symtab.memory_of_fn syms fn in
      let len = Memmap.to_sequence mem |> Seq.fold ~init:0
                  ~f:(fun n (mem,_) -> n + Memory.length mem) in
      fprintf f "%-4d" len in

    let pp_sym = List.map options.print_symbols ~f:(function
        | `with_name -> pp_name
        | `with_addr -> pp_addr
        | `with_size -> pp_size) |> pp_concat ~sep:pp_print_space in

    if options.print_symbols <> [] then
      Project.symbols project |> Symtab.to_sequence |>
      Seq.iter ~f:(printf "@[%a@]@." pp_sym);

    let pp_blk = List.map dump ~f:(function
        | `with_asm -> pp_blk Block.insns pp_insns
        | `with_bil -> pp_blk Helpers.bil_of_block pp_bil) |> pp_concat in

    Text_tags.install std_formatter `Text;
    if dump <> [] then
      pp_code (pp_syms pp_blk) std_formatter syms;

    if options.verbose <> false then
      pp_errs std_formatter (Disasm.errors (Project.disasm project));

    let () =
      if options.output_phoenix <> None then
        let module Phoenix = Phoenix.Make(Env) in
        let dest = Phoenix.store () in
        printf "Stored data in folder %s@." dest in

    if options.dump_symbols <> None then
      let serialized =
        Symtab.to_sequence syms |> Seq.fold ~init:[] ~f:(fun acc fn ->
            let name = Symtab.name_of_fn fn in
            let emem = Block.memory (Symtab.entry_of_fn fn) in
            let es = Memory.min_addr in
            let ef = Memory.max_addr in
            let hd = (name,es emem,ef emem) in
            let tl = Symtab.memory_of_fn syms fn |> Memmap.to_sequence in
            hd :: Seq.fold tl ~init:acc ~f:(fun acc (mem,_) ->
                if Addr.(ef mem = ef emem)
                then acc else (name, es mem, ef mem) :: acc)) in
      match Option.join options.dump_symbols with
      | Some name -> Out_channel.with_file name
                       ~f:(fun oc -> Symbols.write oc serialized)
      | None -> Symbols.write stdout serialized

  let main () =
    let usr_syms arch =
      extract_symbols options.symsfile ~f:(fun filename ->
          In_channel.with_file filename ~f:(Symbols.read arch)) in
    let ida_syms arch =
      extract_symbols options.use_ida ~f:(fun ida ->
          Ida.(with_file ?ida options.filename
                 (fun ida -> get_symbols ida arch)) |> function
          | Ok syms -> syms
          | Error err ->
            eprintf "Failed to extract symbols from IDA: %a@."
              Error.pp err; []) in
    let ext_syms arch = match options.demangle with
      | None -> usr_syms arch @ ida_syms arch
      | Some way ->
        let tool = match way with
          | `program tool -> Some tool
          | `internal -> None in
        List.map (usr_syms arch @ ida_syms arch)
          ~f:(fun (name,es,ef) -> Symbols.demangle ?tool name, es, ef) in
    let symbols arch =
      List.fold (ext_syms arch)
        ~init:(String.Map.empty,Addr.Map.empty)
        ~f:(fun (names,addrs) (name,addr,_) ->
            if Map.mem names name then names,addrs
            else Map.add names ~key:name ~data:addr,
                 Map.add addrs ~key:addr ~data:name) |> snd in
    match options.binaryarch with
    | None ->
      Image.create ~backend:options.loader options.filename >>=
      fun (img,warns) ->
      if options.verbose then
        List.iter warns ~f:(eprintf "Warning: %a@." Error.pp);
      let arch = Image.arch img in
      let symbols = symbols arch in
      let name = Map.find symbols in
      let roots = Table.foldi (Image.segments img)
          ~init:(Map.keys symbols) ~f:(fun mem sec roots ->
              if Image.Segment.is_executable sec
              then find_roots arch mem @ roots
              else roots) in
      Project.from_image ~name ~roots img >>= fun proj ->
      run proj;
      return 0
    | Some s -> match Arch.of_string s with
      | None -> eprintf "unrecognized architecture\n"; return 1
      | Some arch ->
        let width_of_arch = arch |> Arch.addr_size |> Size.in_bits in
        let addr = Addr.of_int 0 ~width:width_of_arch in
        let symbols = symbols arch in
        let name = Map.find symbols in
        Memory.of_file (Arch.endian arch) addr options.filename
        >>= fun mem ->
        let roots = find_roots arch mem @ Map.keys symbols in
        Project.from_mem ~name ~roots arch mem >>= fun proj ->
        run proj;
        return 0
end

let start options =
  let module Program = Program(struct
      let options = options
    end) in
  Program.main ()

let program =
  let doc = "Binary Analysis Platform" in
  let man = [
    `S "DESCRIPTION";
    `P "A frontend to the Binary Analysis Platfrom library.
      The tool allows you to inspect binary programs by printing them
      in different representations including assembly, BIL, BIR,
      XML, HTML, JSON, Graphviz dot graphs and so on.";
    `P "The tool is extensible via a plugin system. There're several
       extension points, that allows you:";
    `Pre "
      - write your own analysis;
      - add new serialization formats;
      - adjust printing formats;
      - add new program loaders (i.e. to handle new file formats);
      - provide your own disassembler.";
    `P "The following example shows how to write a simple analysis
  plugin (called a pass in our parlance)";
    `Pre "
      $(b,\\$ cat) mycode.ml
      open Bap.Std
      let main project = print_endline \"Hello, World\"
      let () = Project.register_pass' \"hello\" main";
    `P "Building is easy with our $(b,bapbuild) tool:";
    `Pre "
      $(b, \\$ bapbuild) mycode.plugin";
    `P "And to load into bap:";
    `Pre ("
      $(b, \\$ bap) /bin/ls -lmycode --hello");
    `P "User plugins have access to all the program state, and can
    change it and communicate with other plugins, or just store their
    results in whatever place you like.";
    `I ("Note:", "The $(b,bapbuild) tool is just an $(b,ocamlbuild)
    extended with our rules. It is not needed to build your standalone
    applications, or to build BAP itself.");
    `P "$(mname) also can integrate with IDA. It can sync names with
    IDA, and emit idapython scripts, based on the analysis";
    `S "BUGS";
    `P "Report bugs to \
        https://github.com/BinaryAnalysisPlatform/bap/issues";
    `S "SEE ALSO"; `P "$(b,bap-mc)(1)"
  ] in

  let create
      a b c d e f g h i j k l m n o p q r s t u v x y =
    Options.Fields.create
      a b c d e f g h i j k l m n o p q r s t u v x y [] in
  let open Bap_cmdline_terms in
  let open Cmdliner in

  Term.(pure create
        $filename $loader $symsfile $cfg_format
        $output_phoenix $output_dump $dump_symbols $demangle
        $no_resolve $keep_alive
        $no_inline $keep_consts $no_optimizations
        $binaryarch $verbose $bw_disable $bw_length $bw_threshold
        $print_symbols $use_ida $sigsfile
        $emit_ida_script $load_path $emit_attr),
  Term.info "bap" ~version:Config.pkg_version ~doc ~man

let parse () =
  let argv,passes = Bap_plugin_loader.run_and_get_passes Sys.argv in
  match Cmdliner.Term.eval ~argv ~catch:false program with
  | `Ok opts -> Ok { opts with Options.passes }
  | _ -> Or_error.errorf "nothing to do"

let () =
  at_exit (pp_print_flush err_formatter);
  Printexc.record_backtrace true;
  Plugins.load ();
  match try_with_join (fun () -> parse () >>= start) with
  | Ok n -> exit n
  | Error err -> eprintf "Exiting because %a.@." Error.pp err;
    exit 1
