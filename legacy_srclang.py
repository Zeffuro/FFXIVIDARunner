from contextlib import contextmanager
import os
import re
import sys


HASH_TYPE = re.compile(r"\bstruc_[0-9a-f]{40}\b")
VFT_TYPE = re.compile(r"^(struc_[0-9a-f]{40})(?:_.*)?_vtbl$")


class LegacyParser:
    def __init__(self, srclang, types):
        self.srclang = srclang
        self.types = types
        self.original = srclang.parse_decls_for_srclang
        self.declarations = {}
        self.bases = {}
        self.vtables = set()
        self.finished = False

    def parse(self, lang, til, source, is_path):
        if is_path or lang != self.srclang.SRCLANG_C or self.srclang.get_selected_parser_name() != "clang":
            return self.original(lang, til, source, is_path)
        names = HASH_TYPE.findall(source.split("{", 1)[0])
        if not names:
            return self.original(lang, til, source, is_path)
        if self.finished:
            raise RuntimeError("Structure declarations arrived after finalization")
        name = names[0]
        self.declarations[name] = source
        self.bases[name] = names[1:]
        order, active = [], set()

        def visit(current):
            if current in active:
                raise RuntimeError("Circular declaration dependency: " + current)
            if current in order:
                return
            if current not in self.declarations:
                raise RuntimeError("Missing base declaration: " + current)
            active.add(current)
            for base in self.bases[current]:
                visit(base)
            active.remove(current)
            order.append(current)

        visit(name)
        before = {item: self.types.get_named_type_tid(item) for item in order}
        forwards = []
        for item in order:
            tag = re.match(r"\s*(struct|union)\b", self.declarations[item])
            if tag is None:
                raise RuntimeError("Unsupported declaration: " + item)
            forwards.append(tag.group(1) + " " + item + ";")
        combined = "\n".join(forwards + [self.declarations[item] for item in order])
        errors = self.srclang.parse_decls_with_parser_ext("clang", til, combined, self.types.HTI_STANDALONE)
        if errors == 0:
            for item in order:
                if self.types.get_named_type_tid(item) != before[item]:
                    raise RuntimeError("Parser changed the type ID for " + item)
                if "virtual void _placeholder();" in self.declarations[item]:
                    self.vtables.add(item + "_vtbl")
        return errors

    def layout(self, name):
        info = self.types.tinfo_t()
        if not info.get_named_type(None, name):
            raise RuntimeError("Missing imported type: " + name)
        details = self.types.udt_type_data_t()
        if not info.get_udt_details(details):
            raise RuntimeError("Missing structure details: " + name)
        return info.get_size(), [(m.name, m.offset, m.size, m.is_baseclass()) for m in details]

    def finish(self):
        layouts = {name: self.layout(name) for name in self.declarations}
        tables = set(self.vtables)
        owners = {name[:-5] for name in tables}
        for ordinal in range(1, self.types.get_ordinal_limit(None)):
            info = self.types.tinfo_t()
            if not info.get_numbered_type(None, ordinal):
                continue
            name = info.get_type_name() or ""
            match = VFT_TYPE.fullmatch(name)
            if match and match.group(1) in owners:
                tables.add(name)
        for name in sorted(tables):
            info = self.types.tinfo_t()
            if not info.get_named_type(None, name):
                raise RuntimeError("Missing temporary vtable: " + name)
            details = self.types.udt_type_data_t()
            if not info.get_udt_details(details) or not details.is_vftable():
                raise RuntimeError("Missing vtable details: " + name)
            if any(member.name != "_placeholder" or not member.type.is_funcptr() for member in details):
                raise RuntimeError("Unexpected temporary vtable member in " + name)
            for index in reversed(range(len(details))):
                if info.del_udm(index) != self.types.TERR_OK:
                    raise RuntimeError("Could not remove temporary vtable member in " + name)
        for name, layout in layouts.items():
            if self.layout(name) != layout:
                raise RuntimeError("Vtable cleanup changed the layout of " + name)
        self.vtables.clear()
        self.finished = True


@contextmanager
def declarations(script_path, options):
    if options["importer"] != "srclang":
        yield
        return
    import idaapi

    if idaapi.IDA_SDK_VERSION < 950:
        yield
        return
    import ida_srclang

    if ida_srclang.get_selected_parser_name() != "clang":
        yield
        return
    import ida_typeinf

    previous_path = sys.path[:]
    sys.path.insert(0, os.path.dirname(os.path.abspath(script_path)))
    try:
        from ida_wrapper import BaseIdaInterface
    finally:
        sys.path[:] = previous_path
    parser = LegacyParser(ida_srclang, ida_typeinf)
    original_rename = BaseIdaInterface.rename_struct

    def rename(instance, tid, name):
        if parser.declarations and not parser.finished:
            parser.finish()
        return original_rename(instance, tid, name)

    ida_srclang.parse_decls_for_srclang = parser.parse
    BaseIdaInterface.rename_struct = rename
    try:
        yield
        if parser.vtables:
            raise RuntimeError("Temporary vtables were not finalized")
    finally:
        ida_srclang.parse_decls_for_srclang = parser.original
        BaseIdaInterface.rename_struct = original_rename
