
// Fast and dirty debug printing
p:: (args: ..Any) {
    for args {
        print("%", it);
        if it_index != args.count-1 then print(", ");
    }
    print("\n");
}

code_to_string:: (code: Code) -> string #expand {
    PP      :: #import "Program_Print";
    Compiler:: #import "Compiler";
    code_node:= Compiler.compiler_get_nodes(code);
    builder: String_Builder;
    PP.print_expression(*builder, code_node);
    return builder_to_string(*builder, allocator=temp);
}

// Inline debug printing
pi:: ($code: Code, loc := #caller_location) -> code.type #expand {
    String:: #import "String";
    result:= #insert code;
    filename:= String.path_filename(loc.fully_pathed_filename);
    log("[%:%] % = %", filename, loc.line_number, #run code_to_string(code), result);
    return result;
}

Log_Allocator :: struct {
    backing_allocator: Allocator;
}

make_log_allocator :: (backing_allocator: Allocator) -> Log_Allocator {
    log: Log_Allocator;
    log.backing_allocator = backing_allocator;
    return log;
}

log_allocator :: (log: *Log_Allocator) -> Allocator {
    return Allocator.{log_allocator_proc, log};
}

log_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory_pointer: *void, allocator_data: *void) -> *void {
    log := cast(*Log_Allocator)allocator_data;
    if size >= 500_000_000 {
        print("[Log_Allocator] % bytes.\n", size);
        print_stack_trace(context.stack_trace);
    }
    return log.backing_allocator.proc(mode, size, old_size, old_memory_pointer, log.backing_allocator.data);
}

#scope_file
#import "Basic";