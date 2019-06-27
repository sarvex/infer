(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** SLEdge command line interface *)

open Command.Let_syntax

type 'a param = 'a Command.Param.t

(* reverse application in the Command.Param applicative *)
let ( |*> ) : 'a param -> ('a -> 'b) param -> 'b param =
 fun x f -> x |> Command.Param.apply f

(* function composition in the Command.Param applicative *)
let ( >*> ) : ('a -> 'b) param -> ('b -> 'c) param -> ('a -> 'c) param =
 fun f' g' -> Command.Param.both f' g' >>| fun (f, g) -> f >> g

(* define a command, with trace flag, and with action wrapped in reporting *)
let command ~summary ?readme param =
  let trace_flag =
    let open Command.Param in
    flag "trace" ~doc:"<spec> enable debug tracing"
      (optional_with_default Trace.none
         (Arg_type.create (fun s -> Trace.parse s |> Result.ok_exn)))
    >>| fun config -> Trace.init ~config ()
  in
  let wrap main () =
    try
      main () |> ignore ;
      Trace.flush () ;
      Format.printf "@\nRESULT: Success@."
    with exn ->
      let bt = Caml.Printexc.get_raw_backtrace () in
      Trace.flush () ;
      ( match exn with
      | Frontend.Invalid_llvm msg ->
          Format.printf "@\nRESULT: Invalid input: %s@." msg
      | Unimplemented msg ->
          Format.printf "@\nRESULT: Unimplemented: %s@." msg
      | Failure msg -> Format.printf "@\nRESULT: Internal error: %s@." msg
      | _ ->
          Format.printf "@\nRESULT: Unknown error: %s@."
            (Caml.Printexc.to_string exn) ) ;
      Caml.Printexc.raise_with_backtrace exn bt
  in
  Command.basic ~summary ?readme (trace_flag *> param >>| wrap)

let marshal program file =
  Out_channel.with_file file ~f:(fun oc ->
      Marshal.to_channel oc program [Marshal.Closures] )

let unmarshal file () =
  In_channel.with_file
    ~f:(fun ic -> (Marshal.from_channel ic : Llair.t))
    file

let analyze =
  let%map_open bound =
    flag "bound"
      (optional_with_default 1 int)
      ~doc:"<int> stop execution exploration at depth <int>"
  and skip_throw =
    flag "skip-throw" no_arg
      ~doc:"do not explore past throwing an exception"
  and function_summaries =
    flag "function-summaries" no_arg
      ~doc:"Use function summaries (in development)"
  in
  fun program () ->
    Control.exec_pgm {bound; skip_throw; function_summaries} (program ())

let analyze_cmd =
  let summary = "analyze LLAIR code" in
  let readme () =
    "The <input> file must be binary LLAIR, such as produced by `sledge \
     translate`."
  in
  let param =
    Command.Param.(anon ("<input>" %: string) >>| unmarshal |*> analyze)
  in
  command ~summary ~readme param

let translate =
  let%map_open output =
    flag "output-llair" (optional string)
      ~doc:"<file> write generated LLAIR to <file>"
  in
  fun bitcode_inputs () ->
    let program = Frontend.translate bitcode_inputs in
    Option.iter ~f:(marshal program) output ;
    program

let llvm_grp =
  let translate_inputs =
    let expand_argsfile input =
      if Char.(input.[0] = '@') then
        In_channel.with_file ~f:In_channel.input_lines
          (String.subo ~pos:1 input)
      else [input]
    in
    let open Command.Param in
    let input_arg = Arg_type.map string ~f:expand_argsfile in
    anon
      (map_anons ~f:List.concat
         (non_empty_sequence_as_list ("<input>" %: input_arg)))
    |*> translate
  in
  let translate_cmd =
    let summary = "translate LLVM bitcode to LLAIR" in
    let readme () =
      "Translate one or more LLVM bitcode files to LLAIR. Each <input> \
       filename may be either: an LLVM bitcode file, in binary (.bc) or \
       textual (.ll) form; or of the form @<argsfile>, where <argsfile> \
       names a file containing one <input> per line."
    in
    let param = translate_inputs in
    command ~summary ~readme param
  in
  let analyze_cmd =
    let summary = "analyze LLVM bitcode" in
    let readme () =
      "Analyze code in one or more LLVM bitcode files. This is a \
       convenience wrapper for the sequence `sledge llvm translate`; \
       `sledge analyze`."
    in
    let param = translate_inputs |*> analyze in
    command ~summary ~readme param
  in
  let summary = "integration with LLVM" in
  let readme () =
    "Code can be provided by one or more LLVM bitcode files."
  in
  Command.group ~summary ~readme ~preserve_subcommand_order:()
    [("analyze", analyze_cmd); ("translate", translate_cmd)]

let disassemble_cmd =
  let summary = "print LLAIR code in textual form" in
  let readme () =
    "The <input> file must be LLAIR code, as produced by `sledge llvm \
     translate`."
  in
  let param =
    let%map_open input = anon ("<input>" %: string)
    and output =
      flag "output" (optional string)
        ~doc:
          "<file> write generated textual LLAIR to <file>, or to standard \
           output if omitted"
    in
    fun () ->
      let program = unmarshal input () in
      match output with
      | None -> Format.printf "%a@." Llair.pp program
      | Some file ->
          Out_channel.with_file file ~f:(fun oc ->
              let fs = Format.formatter_of_out_channel oc in
              Format.fprintf fs "%a@." Llair.pp program )
  in
  command ~summary ~readme param

let summary = "SLEdge static analyzer"

let readme () =
  "The [-trace <spec>] argument of each subcommand enables debug tracing \
   according to <spec>, which is a sequence of module and function names \
   separated by + or -. For example, M-M.f enables all tracing in the M \
   module except the M.f function. The <spec> value * enables all debug \
   tracing."

;;
Command.run ~version:Version.version ~build_info:""
  (Command.group ~summary ~readme ~preserve_subcommand_order:()
     [ ("buck", Sledge_buck.main ~command ~analyze:(translate >*> analyze))
     ; ("llvm", llvm_grp); ("analyze", analyze_cmd)
     ; ("disassemble", disassemble_cmd) ])
