"""Unattended options for the reworked ClientStructs IDA scripts."""

import importlib.util
import os
import sys
from contextlib import contextmanager


def validate_environment(config):
    if sys.version_info < (3, 10):
        raise RuntimeError("The reworked ClientStructs scripts need Python 3.10 or newer in IDA")
    missing = [
        package
        for module, package in (("yaml", "pyyaml"), ("anytree", "anytree"), ("pythonnet", "pythonnet"))
        if importlib.util.find_spec(module) is None
    ]
    if missing:
        raise RuntimeError(
            "Install these packages in IDA's Python environment: " + " ".join(missing)
        )

    import yaml

    script_directory = os.path.dirname(config["client_structs_script"])
    data_path = os.path.join(script_directory, "..", "data.yml")
    with open(data_path, encoding="utf-8-sig") as handle:
        version = str(yaml.safe_load(handle)["version"])
    game_directory = config["game_directory"]
    with open(os.path.join(game_directory, "ffxivgame.ver"), encoding="utf-8-sig") as handle:
        game_version = handle.read().strip()
    if version != game_version:
        raise RuntimeError(f"ClientStructs data version {version} does not match game {game_version}")
    if not os.path.isdir(os.path.join(game_directory, "sqpack")) or not os.path.isdir(
        os.path.join(game_directory, "..", "boot")
    ):
        raise RuntimeError("The reworked scripts need a game install with game/sqpack and boot")
    return version


def form_answers(fields, options, version):
    keys = {field["key"] for field in fields if field.get("key")}
    if keys == {"function_types", "base_name"}:
        expected = {
            "function_types": ("checks", ["virtual", "member"]),
            "base_name": ("radios", ["ffxiv_dx11.exe", "__ImageBase"]),
        }
        for field in fields:
            if field.get("key") in expected:
                kind, items = expected[field["key"]]
                if field["type"] != kind or [item[0] for item in field["items"]] != items:
                    raise RuntimeError("ClientStructs form options changed; runner needs updating")
        return {
            "function_types": {
                "virtual": options["update_virtual_function_types"],
                "member": options["update_member_function_types"],
            },
            "base_name": options["image_base_name"],
        }
    labels = [field.get("text") for field in fields if field["type"] == "label"]
    if not keys and "Check version match." in labels and f"Loaded with ver: {version}" in labels:
        return {}
    raise RuntimeError("Unrecognized ClientStructs form; refusing to guess its answers")


def heads_until_call(interface, ea, func_name):
    import idautils
    import ida_ua

    target = interface.get_func_ea_by_name(func_name)
    if target == interface.BADADDR:
        raise RuntimeError(f"Lua naming target was not found: {func_name}")
    # IDA can render dots as underscores in operands; compare addresses.
    instruction = ida_ua.insn_t()
    for address in idautils.FuncItems(ea):
        if (ida_ua.decode_insn(instruction, address)
                and ida_ua.print_insn_mnem(address).lower() == "call"
                and instruction.ops[0].type in (ida_ua.o_near, ida_ua.o_far)
                and instruction.ops[0].addr == target):
            return
        yield address
    raise RuntimeError(f"Lua naming found no call to {func_name} in function {ea:#x}")


@contextmanager
def unattended_options(config, version):
    script_directory = os.path.dirname(config["client_structs_script"])
    previous_path = sys.path[:]
    sys.path[:0] = [script_directory, os.path.abspath(os.path.join(script_directory, "..", "shared"))]
    try:
        import form_builder
        import lumina_wrapper
        from ida_wrapper import IdaInterface
        import ida_srclang
        import ida_typeinf

        original_form = form_builder.DynamicForm
        original_find_game = lumina_wrapper.find_game_path
        original_parse = IdaInterface.parse_string
        original_heads = IdaInterface.heads_until_call
        original_select = IdaInterface.select_parser
        original_parse_decls = ida_srclang.parse_decls_with_parser
        original_set_args = ida_srclang.set_parser_argv
        headers_checked = False

        class UnattendedForm:
            def __init__(self, fields, on_change=None):
                self.answers = form_answers(fields, config["client_structs"], version)

            def Compile(self):
                pass

            def Execute(self):
                return 1

            def results(self):
                return self.answers

            def Free(self):
                pass

        def checked_parse(interface, *args, **kwargs):
            errors = original_parse(interface, *args, **kwargs)
            if errors:
                raise RuntimeError(f"ClientStructs Clang import reported {errors} error(s)")
            return errors

        def checked_declarations(*args, **kwargs):
            errors = original_parse_decls(*args, **kwargs)
            if errors:
                raise RuntimeError(
                    f"ClientStructs Clang parser reported {errors} error(s). "
                    "Check the log and use MSVC headers compatible with IDA's Clang."
                )
            return errors

        def parser_args(parser, arguments):
            include = config["client_structs"].get("msvc_include_directory")
            if parser == "clang" and include:
                arguments += f' -I"{include}"'
            return original_set_args(parser, arguments)

        def select_parser(interface):
            nonlocal headers_checked
            original_select(interface)
            if not headers_checked:
                til = ida_typeinf.new_til("runner_headers.til", "ClientStructs header check")
                try:
                    checked_declarations(
                        "clang", til,
                        "#define _ITERATOR_DEBUG_LEVEL 0\n#include <vector>\n"
                        "struct runner_header_probe { std::vector<int> value; };", False,
                    )
                finally:
                    ida_typeinf.free_til(til)
                headers_checked = True

        form_builder.DynamicForm = UnattendedForm
        # ida_wrapper imported the class before it was replaced above.
        import ida_wrapper

        original_wrapper_form = ida_wrapper.DynamicForm
        ida_wrapper.DynamicForm = UnattendedForm
        lumina_wrapper.find_game_path = lambda: os.path.dirname(config["game_directory"])
        IdaInterface.parse_string = checked_parse
        IdaInterface.heads_until_call = heads_until_call
        IdaInterface.select_parser = select_parser
        ida_srclang.parse_decls_with_parser = checked_declarations
        ida_srclang.set_parser_argv = parser_args
        try:
            yield
        finally:
            form_builder.DynamicForm = original_form
            ida_wrapper.DynamicForm = original_wrapper_form
            lumina_wrapper.find_game_path = original_find_game
            IdaInterface.parse_string = original_parse
            IdaInterface.heads_until_call = original_heads
            IdaInterface.select_parser = original_select
            ida_srclang.parse_decls_with_parser = original_parse_decls
            ida_srclang.set_parser_argv = original_set_args
    finally:
        sys.path[:] = previous_path


def run(config, execute_script):
    version = validate_environment(config)
    with unattended_options(config, version):
        execute_script(config["client_structs_script"])
