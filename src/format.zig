const std = @import("std");
const mem = std.mem;
const leb = std.debug.leb;
const ArrayList = std.ArrayList;
const Instruction = @import("instruction.zig").Instruction;

pub const Format = struct {
    alloc: *mem.Allocator,
    module: []const u8 = undefined,
    buf: std.io.FixedBufferStream([]const u8) = undefined,

    pub fn init(alloc: *mem.Allocator, module: []const u8) Format {
        return Format{
            .alloc = alloc,
            .module = module,
            .buf = std.io.fixedBufferStream(module),
        };
    }

    pub fn readModule(self: *Format) !Module {
        const rd = self.buf.reader();

        const magic = try rd.readBytesNoEof(4);
        if (!mem.eql(u8, magic[0..], "\x00asm")) return error.MagicNumberNotFound;

        const version = try rd.readIntLittle(u32);

        return Module{
            .version = version,
            .customs = Customs.init(self.alloc),
            .types = Types.init(self.alloc),
            .value_types = ValueTypes.init(self.alloc),
            .imports = Imports.init(self.alloc),
            .functions = Functions.init(self.alloc),
            .tables = Tables.init(self.alloc),
            .memories = Memories.init(self.alloc),
            .globals = Globals.init(self.alloc),
            .exports = Exports.init(self.alloc),
            .start = undefined,
            // .elements = Elements.init(self.alloc),
            .codes = Codes.init(self.alloc),
            .datas = Datas.init(self.alloc),
        };
    }

    pub fn readSection(self: *Format, module: *Module) !SectionType {
        const rd = self.buf.reader();
        const id: SectionType = @intToEnum(SectionType, try rd.readByte());

        const size = try leb.readULEB128(u32, rd);

        _ = switch (id) {
            .Custom => try self.readCustomSection(module, size),
            .Type => try self.readTypeSection(module),
            .Import => try self.readImportSection(module),
            .Function => try self.readFunctionSection(module),
            .Table => try self.readTableSection(module),
            .Memory => try self.readMemorySection(module),
            .Global => try self.readGlobalSection(module),
            .Export => try self.readExportSection(module),
            .Start => try self.readStartSection(module),
            .Code => try self.readCodeSection(module),
            .Data => try self.readDataSection(module, size),
        };

        return id;
    }

    fn readTypeSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const functype_count = try leb.readULEB128(u32, rd);

        var f: usize = 0;
        while (f < functype_count) : (f += 1) {
            const tag: u8 = try rd.readByte();
            if (tag != 0x60) return error.ExpectedFuncTypeTag;

            const param_count = try leb.readULEB128(u32, rd);
            const param_offset = module.value_types.items.len;

            {
                var i: usize = 0;
                while (i < param_count) : (i += 1) {
                    const v = try rd.readEnum(ValueType, .Little);
                    try module.value_types.append(v);
                }
            }

            const results_count = try leb.readULEB128(u32, rd);
            const results_offset = module.value_types.items.len;

            {
                var i: usize = 0;
                while (i < results_count) : (i += 1) {
                    const r = try rd.readEnum(ValueType, .Little);
                    try module.value_types.append(r);
                }
            }

            // TODO: rather than count we could store the first element / last element + 1
            // TODO: should we just index into the existing module data?
            try module.types.append(FuncType{
                .params_offset = param_offset,
                .params_count = param_count,
                .results_offset = results_offset,
                .results_count = results_count,
            });
        }

        return functype_count;
    }

    fn readImportSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const count = try leb.readULEB128(u32, rd);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const module_name_length = try leb.readULEB128(u32, rd);
            const module_name = self.module[rd.context.pos .. rd.context.pos + module_name_length];
            try rd.skipBytes(module_name_length, .{});

            const name_length = try leb.readULEB128(u32, rd);
            const name = self.module[rd.context.pos .. rd.context.pos + name_length];
            try rd.skipBytes(name_length, .{});

            const desc_tag = try rd.readEnum(DescTag, .Little);
            const desc = try rd.readByte(); // TODO: not sure if this is a byte or leb

            try module.imports.append(Import{
                .module = module_name,
                .name = name,
                .desc_tag = desc_tag,
                .desc = desc,
            });
        }

        return count;
    }

    fn readFunctionSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const count = try leb.readULEB128(u32, rd);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const type_index = try leb.readULEB128(u32, rd);
            try module.functions.append(type_index);
        }

        return count;
    }

    fn readTableSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const count = try leb.readULEB128(u32, rd);

        const tag = try rd.readByte();
        if (tag != 0x70) return error.ExpectedTable;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const limit_type = try rd.readEnum(LimitType, .Little);
            switch (limit_type) {
                .Min => {
                    const min = try leb.readULEB128(u32, rd);

                    try module.tables.append(Limit{
                        .min = min,
                        .max = std.math.maxInt(u32),
                    });
                },
                .MinMax => {
                    const min = try leb.readULEB128(u32, rd);
                    const max = try leb.readULEB128(u32, rd);

                    try module.tables.append(Limit{
                        .min = min,
                        .max = max,
                    });
                },
            }
        }

        return count;
    }

    fn readMemorySection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const count = try leb.readULEB128(u32, rd);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const limit_type = try rd.readEnum(LimitType, .Little);
            switch (limit_type) {
                .Min => {
                    const min = try leb.readULEB128(u32, rd);

                    try module.memories.append(Limit{
                        .min = min,
                        .max = std.math.maxInt(u32),
                    });
                },
                .MinMax => {
                    const min = try leb.readULEB128(u32, rd);
                    const max = try leb.readULEB128(u32, rd);

                    try module.memories.append(Limit{
                        .min = min,
                        .max = max,
                    });
                },
            }
        }

        return count;
    }

    fn readGlobalSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const count = try leb.readULEB128(u32, rd);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const global_type = try rd.readEnum(ValueType, .Little);
            const mutability = try rd.readEnum(Mutability, .Little);
            const offset = rd.context.pos;

            var j: usize = 0;
            while (true) : (j += 1) {
                const byte = try rd.readByte();
                if (byte == @enumToInt(Instruction.End)) break;
            }
            const code = self.module[offset .. offset + j + 1];

            try module.globals.append(Global{
                .value_type = global_type,
                .mutability = mutability,
                .code = code,
            });
        }

        return count;
    }

    fn readExportSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const count = try leb.readULEB128(u32, rd);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const name_length = try leb.readULEB128(u32, rd);
            const name = self.module[rd.context.pos .. rd.context.pos + name_length];
            try rd.skipBytes(name_length, .{});

            const tag = try rd.readEnum(DescTag, .Little);
            const index = try leb.readULEB128(u32, rd);

            try module.exports.append(Export{
                .name = name,
                .tag = tag,
                .index = index,
            });
        }

        return count;
    }

    fn readStartSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        const index = try leb.readULEB128(u32, rd);

        module.start = index;

        return 1;
    }

    fn readCodeSection(self: *Format, module: *Module) !usize {
        const rd = self.buf.reader();
        var x = rd.context.pos;
        const count = try leb.readULEB128(u32, rd);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const size = try leb.readULEB128(u32, rd); // includes bytes defining locals
            const offset = rd.context.pos;
            try rd.skipBytes(size, .{});
            const code = self.module[offset..rd.context.pos];

            try module.codes.append(Code{
                .code = code,
            });
        }

        return count;
    }

    fn readDataSection(self: *Format, module: *Module, size: u32) !usize {
        const rd = self.buf.reader();
        var section_offset = rd.context.pos;
        const count = try leb.readULEB128(u32, rd);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const mem_idx = try leb.readULEB128(u32, rd);
            const instr = try rd.readEnum(Instruction, .Little);
            const mem_offset = try leb.readULEB128(u32, rd);
            const data_length = try leb.readULEB128(u32, rd);

            const offset = rd.context.pos;
            try rd.skipBytes(data_length, .{});
            const data = self.module[offset..rd.context.pos];

            try module.datas.append(Data{
                .mem_idx = mem_idx,
                .instr = instr,
                .mem_offset = mem_offset,
                .data = data,
            });
        }

        const remaining_data = size - (rd.context.pos - section_offset);
        try rd.skipBytes(remaining_data, .{});

        return count;
    }

    fn readCustomSection(self: *Format, module: *Module, size: u32) !usize {
        const rd = self.buf.reader();
        const offset = rd.context.pos;

        const name_length = try leb.readULEB128(u32, rd);
        const name = self.module[rd.context.pos .. rd.context.pos + name_length];
        try rd.skipBytes(name_length, .{});

        const remaining_size = size - (rd.context.pos - offset);

        const data = self.module[rd.context.pos .. rd.context.pos + remaining_size];
        try rd.skipBytes(remaining_size, .{});

        try module.customs.append(Custom{
            .name = name,
            .data = data,
        });

        return 1;
    }
};

pub const Module = struct {
    version: u32,
    customs: Customs,
    types: Types,
    value_types: ValueTypes,
    imports: Imports,
    functions: Functions,
    tables: Tables,
    memories: Memories,
    globals: Globals,
    exports: Exports,
    start: u32,
    // elements: Elements,
    codes: Codes,
    datas: Datas,
};

const Section = struct {
    id: SectionType,
    size: u32,
    contents: []const u8,
};

const Custom = struct {
    name: []const u8,
    data: []const u8,
};

const LimitType = enum(u8) {
    Min,
    MinMax,
};

const Limit = struct {
    min: u32,
    max: u32,
};

const Mutability = enum(u8) {
    Immutable,
    Mutable,
};

const SectionType = enum(u8) {
    Custom = 0x00,
    Type = 0x01,
    Import = 0x02,
    Function = 0x03,
    Table = 0x04,
    Memory = 0x05,
    Global = 0x06,
    Export = 0x07,
    Start = 0x08,
    // Element = 0x09,
    Code = 0x0a,
    Data = 0x0b,
};

const ValueType = enum(u8) {
    I32 = 0x7F,
    I64 = 0x7E,
    F32 = 0x7D,
    F64 = 0x7C,
};

// TODO: should we define these?
const Customs = ArrayList(Custom);
const Types = ArrayList(FuncType);
const ValueTypes = ArrayList(ValueType);
const Imports = ArrayList(Import);
const Functions = ArrayList(u32); // We can't use view into data because values are leb
const Tables = ArrayList(Limit);
const Memories = ArrayList(Limit);
const Globals = ArrayList(Global);
const Exports = ArrayList(Export);
const Codes = ArrayList(Code);
const Locals = ArrayList(Local);
const Datas = ArrayList(Data);

const FuncType = struct {
    params_offset: usize,
    params_count: usize,
    results_offset: usize,
    results_count: usize,
};

const Global = struct {
    value_type: ValueType,
    mutability: Mutability,
    code: []const u8,
};

const Import = struct {
    module: []const u8,
    name: []const u8,
    desc_tag: DescTag,
    desc: u8,
};

const Export = struct {
    name: []const u8,
    tag: DescTag,
    index: u32,
};

const Code = struct {
    code: []const u8,
};

const Data = struct {
    mem_idx: u32,
    instr: Instruction,
    mem_offset: u32,
    data: []const u8,
};

const DescTag = enum(u8) {
    Func,
    Table,
    Mem,
    Global,
};
