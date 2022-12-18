
#import "Basic";
#import "Bindings_Generator";
#import "Compiler";
#import "File";
#import "String";

SRC_PATH:: "src";

#run {
    set_build_options_dc(.{do_output=false});
    if !generate_bindings() {
        compiler_set_workspace_status(.FAILED);
    }
}

generate_bindings:: () -> bool {
    output_filename: string;
    opts: Generate_Bindings_Options;
    {
        using opts;

        #if OS == .WINDOWS {
            output_filename = "../generated_windows.jai";
        } else {
            assert(false);
        }

        array_add(*libnames, "odbc32");
        array_add(*system_include_paths, GENERATOR_DEFAULT_SYSTEM_INCLUDE_PATH);
        array_add(*include_paths, SRC_PATH);
        array_add(*source_files, tprint("%/sql.h", SRC_PATH));
        array_add(*source_files, tprint("%/sqlucode.h", SRC_PATH));
        auto_detect_enum_prefixes = false;
        generate_compile_time_struct_checks = false;
        footer = FOOTER;
    }

    return generate_bindings(opts, output_filename); // Call bindings generator
}


FOOTER:: #string DONE
#scope_file
#import "Windows";
#load "odbc_windows_extras.jai";
DONE