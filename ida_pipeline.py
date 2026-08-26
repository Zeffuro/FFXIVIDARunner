"""IDA-side stages for FFXIV IDA Runner."""

import __future__
import json
import os
import sys
import time
import traceback

import ida_auto
import ida_funcs
import ida_hexrays
import ida_kernwin
import ida_loader
import ida_pro
import idc


PIPELINE_CONFIG_ENV = "_FFXIV_IDA_PIPELINE_CONFIG"


def load_config():
    config_path = os.environ.get(PIPELINE_CONFIG_ENV)
    if not config_path:
        config_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "config.json")
    if not os.path.isfile(config_path):
        raise RuntimeError(f"Config file not found: {config_path}")
    with open(config_path, "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_status(config, stage, state="running", **details):
    status = {
        "state": state,
        "stage": stage,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        **details,
    }
    status_path = config["status_path"]
    temporary_path = status_path + ".tmp"
    with open(temporary_path, "w", encoding="utf-8") as handle:
        json.dump(status, handle, indent=2)
        handle.write("\n")
    os.replace(temporary_path, status_path)
    print(f"[FFXIV-RUNNER] {state}: {stage}")


def execute_python_script(script_path):
    script_path = os.path.abspath(script_path)
    script_directory = os.path.dirname(script_path)
    if script_directory not in sys.path:
        sys.path.insert(0, script_directory)
    namespace = {"__name__": "__main__", "__file__": script_path}
    with open(script_path, "rb") as handle:
        source = handle.read()
    code = compile(
        source,
        script_path,
        "exec",
        flags=__future__.annotations.compiler_flag,
        dont_inherit=True,
    )
    exec(code, namespace, namespace)


def configure_extra_pass_dialog(options):
    from PyQt5.QtCore import QTimer
    from PyQt5.QtWidgets import QApplication, QCheckBox

    state = {"applied": False, "cancelled": False, "error": None, "attempts": 0}
    values = [
        bool(options.get("convert_unknown_data", False)),
        bool(options.get("fix_align_blocks", True)),
        bool(options.get("fix_missing_code", True)),
        bool(options.get("fix_missing_functions", True)),
        bool(options.get("fix_noncontiguous_functions", True)),
        bool(options.get("play_sound", False)),
    ]

    def apply_options():
        if state["cancelled"]:
            return
        state["attempts"] += 1
        widget = QApplication.activeModalWidget()
        if widget is not None and "ExtraPass" in widget.windowTitle():
            checkboxes = widget.findChildren(QCheckBox)
            if len(checkboxes) < len(values):
                state["error"] = f"Expected six ExtraPass checkboxes, found {len(checkboxes)}"
                widget.reject()
                return
            for checkbox, value in zip(checkboxes[: len(values)], values):
                checkbox.setChecked(value)
            state["applied"] = True
            widget.accept()
            return
        if state["attempts"] < 200:
            QTimer.singleShot(50, apply_options)
        else:
            state["error"] = "ExtraPass options dialog did not appear"

    QTimer.singleShot(0, apply_options)
    return state


def run_extra_passes(config):
    options = config["extra_pass"]
    max_runs = int(options.get("max_runs", 5))
    mode = options.get("mode", "configured")
    stable_runs = 0
    previous_count = ida_funcs.get_func_qty()
    results = []
    completed_runs = 0
    attempts = 0

    while completed_runs < max_runs and attempts < max_runs + 3:
        attempts += 1
        ida_auto.auto_wait()
        write_status(
            config,
            "extra_pass",
            pass_number=completed_runs + 1,
            attempt=attempts,
            max_runs=max_runs,
            function_count=previous_count,
        )

        previous_batch_mode = idc.batch(0)
        dialog_state = None
        if mode == "configured":
            dialog_state = configure_extra_pass_dialog(options)
        plugin_started_at = time.monotonic()
        try:
            if not ida_loader.load_and_run_plugin("IDA_ExtraPass_PlugIn", 0):
                raise RuntimeError("ExtraPass failed to load or run")
        finally:
            idc.batch(previous_batch_mode)
        plugin_elapsed = time.monotonic() - plugin_started_at

        if plugin_elapsed < 0.25:
            if dialog_state is not None:
                dialog_state["cancelled"] = True
            print(
                f"[FFXIV-RUNNER] ExtraPass attempt {attempts} returned in "
                f"{plugin_elapsed:.3f}s; retrying"
            )
            ida_auto.auto_wait()
            previous_count = ida_funcs.get_func_qty()
            continue

        if dialog_state is not None:
            if dialog_state["error"]:
                raise RuntimeError(dialog_state["error"])
            if not dialog_state["applied"]:
                raise RuntimeError("ExtraPass options were not applied")

        ida_auto.auto_wait()
        completed_runs += 1
        current_count = ida_funcs.get_func_qty()
        delta = current_count - previous_count
        results.append(
            {
                "pass": completed_runs,
                "attempt": attempts,
                "plugin_elapsed_seconds": round(plugin_elapsed, 3),
                "function_count_before": previous_count,
                "function_count_after": current_count,
                "new_functions": delta,
            }
        )
        print(
            f"[FFXIV-RUNNER] ExtraPass {completed_runs}: "
            f"functions {previous_count} -> {current_count} ({delta:+d})"
        )
        stable_runs = stable_runs + 1 if delta == 0 else 0
        previous_count = current_count
        if completed_runs >= 2 and stable_runs >= 2:
            print("[FFXIV-RUNNER] ExtraPass converged")
            break

    if completed_runs == 0:
        raise RuntimeError("ExtraPass never completed a processing pass")
    return results


def run_client_structs(config):
    options = config["client_structs"]
    original_ask_buttons = ida_kernwin.ask_buttons
    original_ask_yn = ida_kernwin.ask_yn

    def answer_buttons(*args, **kwargs):
        message = str(args[-1]) if args else ""
        if "base offset" in message:
            return (
                ida_kernwin.ASKBTN_YES
                if options["image_base_name"] == "ffxiv_dx11.exe"
                else ida_kernwin.ASKBTN_NO
            )
        if "Which importer" in message:
            return (
                ida_kernwin.ASKBTN_YES
                if options["importer"] == "srclang"
                else ida_kernwin.ASKBTN_NO
            )
        if "padding style" in message:
            return (
                ida_kernwin.ASKBTN_YES
                if options["padding"] == "full"
                else ida_kernwin.ASKBTN_NO
            )
        return ida_kernwin.ASKBTN_YES

    def answer_yes_no(default, message):
        if "member function types" in message:
            value = options["update_member_function_types"]
        elif "virtual function types" in message:
            value = options["update_virtual_function_types"]
        else:
            value = True
        return ida_kernwin.ASKBTN_YES if value else ida_kernwin.ASKBTN_NO

    ida_kernwin.ask_buttons = answer_buttons
    ida_kernwin.ask_yn = answer_yes_no
    try:
        execute_python_script(config["client_structs_script"])
    finally:
        ida_kernwin.ask_buttons = original_ask_buttons
        ida_kernwin.ask_yn = original_ask_yn
    ida_auto.auto_wait()


def create_c_file(config):
    if not ida_hexrays.init_hexrays_plugin():
        raise RuntimeError("The Hex-Rays decompiler is unavailable")
    output_path = config["c_output_path"]
    result = ida_hexrays.decompile_many(
        output_path,
        None,
        ida_hexrays.VDRUN_NEWFILE
        | ida_hexrays.VDRUN_SILENT
        | ida_hexrays.VDRUN_MAYSTOP,
    )
    if not result:
        raise RuntimeError("Hex-Rays batch C-file generation did not complete")
    return output_path


def main():
    started_at = time.time()
    config = None
    try:
        config = load_config()
        write_status(config, "auto_analysis")
        ida_auto.auto_wait()

        extra_pass_results = []
        if config["stages"]["extra_pass"]:
            extra_pass_results = run_extra_passes(config)

        if config["stages"]["client_structs"]:
            write_status(config, "client_structs")
            run_client_structs(config)

        c_output = None
        if config["stages"]["generate_c_file"]:
            write_status(config, "create_c_file")
            c_output = create_c_file(config)

        if config["stages"]["apply_comments"]:
            write_status(config, "comments")
            execute_python_script(config["comments_script"])
            ida_auto.auto_wait()

        write_status(config, "save_database")
        if not ida_loader._ida_loader.save_database():
            raise RuntimeError("IDA failed to save the database")
        ida_loader.flush_buffers()

        write_status(
            config,
            "complete",
            state="complete",
            elapsed_seconds=round(time.time() - started_at, 2),
            database_path=ida_loader.get_path(ida_loader.PATH_TYPE_IDB),
            c_output_path=c_output,
            extra_pass_results=extra_pass_results,
            function_count=ida_funcs.get_func_qty(),
        )
        ida_pro.qexit(0)
    except BaseException as error:
        error_text = "".join(traceback.format_exception(type(error), error, error.__traceback__))
        print("[FFXIV-RUNNER] FAILED\n" + error_text)
        try:
            if config is not None:
                write_status(
                    config,
                    "failed",
                    state="failed",
                    error=str(error),
                    traceback=error_text,
                    elapsed_seconds=round(time.time() - started_at, 2),
                )
        finally:
            ida_pro.qexit(1)


main()
