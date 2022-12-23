#module_parameters(DEBUG:= false); // @incomplete POOL_ALLOCATOR_CUTOFF_SIZE

#scope_file
#import "Basic";
#import "Windows_Utf8";

STRING_LIB:: #import "String"; // equal_nocase
#if DEBUG using UTIL_LIB:: #import,file "util.jai";

#load "generated_windows.jai";


#scope_export
// We have our own wrapper function for 'release'
using,except(release) POOL_LIB:: #import "Pool";


DB_Connection:: struct {
    env: SQLHENV;
    dbc: SQLHDBC;
    stmt: SQLHSTMT;
}

Extra_Data_To_Free:: struct {
    data: *void;
    allocator: Allocator = .{};
}

Data_To_Free:: struct {
    result_pool: Pool;
    extra_data: [..] Extra_Data_To_Free;
}

Unkown_Result_Mode:: enum {
    CRASH;
    WARN;
    SILENT;
}

connect:: (conn_str: string, location:= #caller_location) ->  (state: DB_Connection #must, success: bool) {
    auto_release_temp(); // reports messages can take up a lot

    using state: DB_Connection;

    // Allocate an environment handle
    if !REPORT(env, SQL_HANDLE_ENV, SQLAllocHandle(SQL_HANDLE_ENV, xx SQL_NULL_HANDLE, *env), location) {
        disconnect(*state);
        return state, false;
    }

    // We want ODBC 3 support
    if !REPORT(env, SQL_HANDLE_ENV, SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, cast(*void) SQL_OV_ODBC3, 0), location) {
        disconnect(*state);
        return state, false;
    }

    // Allocate a connection handle
    if !REPORT(env, SQL_HANDLE_ENV, SQLAllocHandle(SQL_HANDLE_DBC, env, *dbc), location) {
        disconnect(*state);
        return state, false;
    }

    // Connect to the DSN
    if !REPORT(dbc, SQL_HANDLE_DBC, SQLDriverConnect(dbc, null, conn_str.data, xx conn_str.count, null, 0, null, SQL_DRIVER_NOPROMPT), location) {
        disconnect(*state);
        return state, false;
    }

    // Allocate a statement handle
    if !REPORT(dbc, SQL_HANDLE_DBC, SQLAllocHandle(SQL_HANDLE_STMT, dbc, *stmt), location) {
        disconnect(*state);
        return state, false;
    }

    return state, true;
}

disconnect:: (using state: *DB_Connection, location:= #caller_location) {
    if stmt then SQLFreeHandle(SQL_HANDLE_STMT, stmt);
    if dbc {
        SQLDisconnect(dbc);
        SQLFreeHandle(SQL_HANDLE_DBC, dbc);
    }
    if env then SQLFreeHandle(SQL_HANDLE_ENV, env);
}

release:: (data_to_free: *Data_To_Free) {
    for data_to_free.extra_data { free(it.data, allocator=it.allocator); }
    POOL_LIB.release(*data_to_free.result_pool);
}


//
// Wrapper for 'execute' with the difference that it automatically 
// frees the result pool on end of scope(defer).
//
// For more information see notes for 'execute'.
//
EXECUTE:: (using connection: *DB_Connection, $T: Type, command: string, args: .. Any, $ignore_unknown:= Unkown_Result_Mode.CRASH, location:= #caller_location) 
                -> (success: bool, results: [] T, has_value: [] bool) #expand {

    success, data_to_free, results, has_value, modified_rows:= execute(connection, T, command, ..args, ignore_unknown=ignore_unknown, location=location) ;
    `defer release(*data_to_free);
    return success, results, has_value;
}

//
// This function should be used for statements that don't return data like
// UPDATE, DELETE etc.
//
// Everything else is the same with the exception, that nothing has to be 
// freed after this call. It's done for you.
//
// Also see note below.
//
execute:: inline (using connection: *DB_Connection, command: string, args: .. Any, location:= #caller_location) -> (success: bool, modified_rows: int) {
    // If this is empty and someone called this with e.g. SELECT it causes a crash since 
    // it will end up calling array_add, which will ultimately call realloc with size 0..
    Dummy:: struct { var: u8;}; 
    // This should technically not allocate anything if called with e.g. DELETE statement, but we free just in case.
    success, data_to_free, results, has_value, modified_rows:= execute(connection, Dummy, command, ..args, ignore_unknown=.CRASH, location=location);
    release(*data_to_free);
    return success, modified_rows;
}

//
// Execute a sql command and parse the result into a given struct.
// Please use parameterized queries with '?' as a placeholder, insead of
// using string modifications them into the command string, to avoid sql injections.
//
// results, has_value, and modified_rows are undefined if success returned false
//
// returns 'true' if everything worked. 'false' if an error occured. It will be in the log.
//
// NOTE: This procedure returns a pool allocator that has to be released(*pool)
//       even if this procedure returns false.
//
execute:: (using connection: *DB_Connection, $T: Type, command: string, args: .. Any, $ignore_unknown:= Unkown_Result_Mode.CRASH, location:= #caller_location) 
                -> (success: bool, data_to_free: Data_To_Free #must, results: [] T, has_value: [] bool, modified_rows: int) {

    // Clean up temp memory after this call since it could be a lot due to unicode strings
    // Maybe do this on a per-column basis?
    temporary_storage_mark:= get_temporary_storage_mark();
    defer set_temporary_storage_mark(temporary_storage_mark);

    if !verify_connection(connection) {
        log_error("Error at: %\nexecute was called with an invalid connection state\n", location_to_path(location));
        return false, .{result_pool=Pool.{}}, T.[], bool.[], 0;
    }

    log("**** Running Query ****\nAt %\n", location_to_path(location), flags=.VERBOSE_ONLY);
    log("%\n", command, flags=.VERBOSE_ONLY);

    // Used for the wide string conversions that are long
    temp_string_pool: Pool;
	set_allocators(*temp_string_pool);
    defer POOL_LIB.release(*temp_string_pool);
    temp_string_allocator: Allocator;
    temp_string_allocator.proc = pool_allocator_proc;
    temp_string_allocator.data = *temp_string_pool;


    // @todo: Let user decide this maybe even on per call basis. He knows the best how big the results will be. :UserOptions
    RESULT_POOL_BUCKET_SIZE:: 65536;
    RESULT_POOL_OVERSIZED_SIZE:: 8192; // 8000 is VARCHAR to VARCHAR(MAX) cutoff

    // Since the results usually have the same lifespan we use a Pool allocator
    // NOTE: This is freed by the user. It has to be freed even if success is false. 
    // Since this function can return at any point when encountering errors.
    result_pool: Pool;
    result_pool.memblock_size = RESULT_POOL_BUCKET_SIZE;
    result_pool.oversized_size = RESULT_POOL_OVERSIZED_SIZE;
	set_allocators(*result_pool);
    result_pool_allocator: Allocator;
    result_pool_allocator.proc = pool_allocator_proc;
    result_pool_allocator.data = *result_pool;

    extra_data_to_free :[..] Extra_Data_To_Free;
    extra_data_to_free.allocator = result_pool_allocator;

    REPORT_MAYBE_RETURN:: (handle: SQLHANDLE, handle_type: SQLSMALLINT, code: Code, library_call_location:= #caller_location, to_ignore: [] int = int.[]) 
                                -> success: bool, return_code: SQLRETURN #expand {

        userspace_caller_location:= `location;
        success, return_code:= REPORT(handle, handle_type, code, userspace_caller_location, library_call_location, to_ignore=to_ignore);
        if !success {
            `return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
        }
        return success, return_code;
    }

    //mask: int;
    //REPORT_MAYBE_RETURN(dbc, SQL_HANDLE_DBC, SQLGetInfo(dbc, SQL_GETDATA_EXTENSIONS, *mask, size_of(type_of(mask)), null));
    //print("****** %\n", formatInt(mask, base=2));
    //print("SQL_GD_ANY_COLUMN=%, SQL_GD_ANY_ORDER=%, SQL_GD_BLOCK=%, SQL_GD_BOUND=%\n", mask & SQL_GD_ANY_COLUMN != 0, mask & SQL_GD_ANY_ORDER != 0, mask & SQL_GD_BLOCK != 0, mask & SQL_GD_BOUND != 0);
    
    /*
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLColumns(stmt, null, 0, null, 0, "Test".data, SQL_NTS, null, 0));
    buffer :[64] u8 ;
    val :Any;
    val.value_pointer = buffer.data;
    indi :int;
    while true {  
        success, ret:= REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLFetch(stmt));
        if !success || ret == SQL_NO_DATA then break;

        for 1..18 {
            if it == {
                case 1; #through;
                case 2; #through;
                case 3; #through;
                case 4; #through;
                case 6; #through;
                case 12; #through;
                case 13; #through;
                case 18;
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, xx it, SQL_C_CHAR, buffer.data, buffer.count, *indi));
                    val = to_string(buffer.data);
                case 5; #through;
                case 9; #through;
                case 10; #through;
                case 11; #through;
                case 14; #through;
                case 15;
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, xx it, SQL_C_SSHORT, buffer.data, buffer.count, *indi));
                    val = <<cast(*s16)buffer.data;
                case 7; #through;
                case 8; #through;
                case 16; #through;
                case 17;
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, xx it, SQL_C_SLONG, buffer.data, buffer.count, *indi));
                    val = <<cast(*s32)buffer.data;
                case; assert(false);
            }
            print("(%) %\n", it, val);
        }
        print("#################\n");
    }
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLCloseCursor(stmt));
    */

    //
    // Bind Input Paramters
    //

    // Indicators need to live until SQLExecuteDirect is called..
    indicators:= NewArray(args.count, s64, allocator=temp);
    for arg, index: args {
        if arg.type.type == {
            case .INTEGER;
                info:= cast(*Type_Info_Integer) arg.type;
                //
                // Not sure whats up with unsigned values. DB doesnt seem to support it, but why is there
                // SQL_C_U... then? For now we just do this. @investigate :IntegerTests
                //
                // -mupu 18/12/2022
                if info.runtime_size == {
                    case 1;
                        if info.signed {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_STINYINT, SQL_TINYINT, 0, 0, arg.value_pointer, 0, null));
                        } else {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_UTINYINT, SQL_TINYINT, 0, 0, arg.value_pointer, 0, null));
                        }
                    case 2;
                        if info.signed {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_SSHORT, SQL_SMALLINT, 0, 0, arg.value_pointer, 0, null));
                        } else {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_USHORT, SQL_SMALLINT, 0, 0, arg.value_pointer, 0, null));
                        }
                    case 4;
                        if info.signed {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_SLONG, SQL_INTEGER, 0, 0, arg.value_pointer, 0, null));
                        } else {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_ULONG, SQL_INTEGER, 0, 0, arg.value_pointer, 0, null));
                        }
                    case 8;
                        if info.signed {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_SBIGINT, SQL_BIGINT, 0, 0, arg.value_pointer, 0, null));
                        } else {
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_UBIGINT, SQL_BIGINT, 0, 0, arg.value_pointer, 0, null));
                        }
                    case;
                        log_error("Error at: %\nINTEGER of runtime size % not supported. Argument=%\n", location_to_path(location), info.runtime_size, index+1);
                        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                }

                log("Bound INTEGER to parameter %, value=%, runtime_size=%, signed=%\n", index+1, arg, info.runtime_size, info.signed, flags=.VERY_VERBOSE_ONLY);

            case .STRING;
                arg_casted:= <<cast(*string) arg.value_pointer;
                allocator:= ifx arg_casted.count > 2048 then temp_string_allocator else temp;
                // Data needs to live until SQLExecute is called.
                // Right now this can take up to 5 GB ram in total.
                // 
                // @todo @investigate @optimize :utf8Conversion This probably should use PutData or smth. 
                // @fix :LongStringInput
                string_wide, success, string_byte_length:= utf8_to_wide(arg_casted, allocator=allocator);
                if !success {
                    log_error("Error at: %\nAt: %\nUTF8 to wide conversion failed!?\n", location_to_path(location), location_to_path(#location()));
                    return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                }
                indicators[index] = string_byte_length;
                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_WCHAR, SQL_WVARCHAR, cast(u64) string_byte_length , 0, string_wide, string_byte_length, *indicators[index]));
                log("Bound STRING to parameter %, value='%'\n", index+1, arg_casted, flags=.VERY_VERBOSE_ONLY);

            case .FLOAT;
                info:= cast(*Type_Info_Float) arg.type;
                if info.runtime_size == 4 {
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_FLOAT, SQL_REAL, 0, 0, arg.value_pointer, 0, null));
                } else if info.runtime_size == 8 {
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_DOUBLE, SQL_DOUBLE, 0, 0, arg.value_pointer, 0, null));
                } else {
                    log_error("Error at: %\nFLOAT of runtime size % not supported. Argument=%\n", location_to_path(location), info.runtime_size, index+1);
                    return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                }
                log("Bound FLOAT to parameter %, value=%\n", index+1, arg, flags=.VERY_VERBOSE_ONLY);
            case .ARRAY;
                info:= cast(*Type_Info_Array) arg.type;
                if !(info.element_type.type == .INTEGER && info.element_type.runtime_size == 1) {
                    log_error("Error at: %\nOnly ARRAY of type 'u8' are supported. Argumet=%\n", location_to_path(location), index+1);
                    return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                }

                // @fix :LongStringInput
                if info.array_type == .FIXED {
                    // For fixed array value_pointer points to array.data. Also we are allowed to
                    // do `*info.array_count`, because it is a constant value.
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_BINARY, SQL_BINARY, xx info.array_count , 0, arg.value_pointer, info.array_count, *info.array_count));
                    log("Bound ARRAY to parameter %, array_type=FIXED, bytes=%\n", index+1, info.array_count, flags=.VERY_VERBOSE_ONLY);
                } else if info.array_type == .RESIZABLE {
                    arg_casted:= cast(*[..] u8) arg.value_pointer;
                    indicators[index] = arg_casted.count;
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_BINARY, SQL_BINARY, xx arg_casted.count , 0, arg_casted.data, arg_casted.count, *indicators[index]));
                    log("Bound ARRAY to parameter %, array_type=RESIZABLE, bytes=%\n", index+1, arg_casted.count, flags=.VERY_VERBOSE_ONLY);
                } else if info.array_type == .VIEW {
                    arg_casted:= cast(*[] u8) arg.value_pointer;
                    indicators[index] = arg_casted.count;
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_BINARY, SQL_BINARY, xx arg_casted.count , 0, arg_casted.data, arg_casted.count, *indicators[index]));
                    log("Bound ARRAY to parameter %, array_type=VIEW, bytes=%\n", index+1, arg_casted.count, flags=.VERY_VERBOSE_ONLY);
                } 
            case .STRUCT;
                info:= cast(*Type_Info_Struct) arg.type;
                if info == type_info(Apollo_Time) {
                    calendar:= to_calendar(<<cast(*Apollo_Time)arg.value_pointer);
                    time_string:= tprint("%-%-% %:%:%.%", calendar.year, calendar.month_starting_at_0+1, calendar.day_of_month_starting_at_0+1, calendar.hour, calendar.minute, calendar.second, calendar.millisecond);
                    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_CHAR, SQL_CHAR, xx time_string.count , 0, time_string.data, time_string.count, *time_string.count));
                    log("Bound Apollo_Time to parameter %, value=% UTC\n", index+1, calendar_to_iso_string(calendar), flags=.VERY_VERBOSE_ONLY);
                } else {
                    log_error("Error at: %\nSTRUCT of type '%' not supported. Argument=%\n", location_to_path(location), info.name, index+1);
                    return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                }
            /*
            case .POINTER;
                info:= cast(*Type_Info_Pointer) arg.type;
                print("% %\n", <<info, info.pointer_to.type);
                if <<cast(**void)arg.value_pointer == null {
                    indicator:= cast(*s64)talloc(size_of(s64));
                    <<indicator = SQL_NULL_DATA;
                   dummy:= tprint("\0");
                   REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLBindParameter(stmt, xx (index + 1), SQL_PARAM_INPUT, SQL_C_CHAR, SQL_INTEGER, 0 , 0, null, 0, indicator));
                    log("Bound parameter (%) - null\n ", index+1, flags=.VERBOSE_ONLY);
                } else {
                    log_error("Only null pointers are supported. Pointer was '%'\n", arg.value_pointer);
                    continue;
                }
                exit(0);
            */
            case;
                log_error("Error at: %\nType '%' not supported\n", location_to_path(location), arg.type.type);
                return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
        }
    }

    //
    // Execute
    //
    command_wide, command_bool, command_byte_length:= utf8_to_wide(command, allocator=temp);
    if !command_bool {
        log_error("Error at: %\nAt: %\nUTF8 to wide conversion failed!?\n", location_to_path(location), location_to_path(#location()));
        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
    }
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLExecDirectW(stmt, command_wide, command_byte_length/2));

    // Free temp storage and temp_string_pool, since unicode strings could have used a lot.
    // It should be save to do here, since SQLExcelDirectW uses all bound buffers and indicators of SQLBindParameters.
    // https://learn.microsoft.com/en-us/sql/odbc/reference/develop-app/deferred-buffers?view=sql-server-ver16
    set_temporary_storage_mark(temporary_storage_mark);
    POOL_LIB.release(*temp_string_pool);

    //
    // Retrieve and parse the result's data
    //
    column_count: u16;
    row_count: s64;
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLNumResultCols(stmt, xx *column_count));
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLRowCount(stmt, *row_count));
    row_count = max(0, row_count); // Its -1 e.g. if it was a SELECT query

    log("Query Result: % columns, % modified rows\n", column_count, row_count, flags=.VERBOSE_ONLY);

    if !column_count then return true, .{result_pool, extra_data_to_free}, T.[], bool.[], row_count; // no data to query

    results: [..] T;
    results.allocator = result_pool_allocator;

    has_value :[..] bool;
    has_value.allocator = result_pool_allocator;

    indicator: int;
    while true { // For all rows in result set
        temp_data: T; // Its in here so its get reset to defaults every row.

        // Fetch single row
        success, fetch_result:= REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLFetch(stmt), to_ignore=.[SQL_NO_DATA]);
        log("Fetch column result: %\n", fetch_result, flags=.VERY_VERBOSE_ONLY);
        if !success || fetch_result == SQL_NO_DATA then break;

        for 1..column_count {
            // Fetch column meta data
            column_name: [32] u8;
            name_length: s16;
            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLColAttribute(stmt, it, SQL_DESC_LABEL, column_name.data, column_name.count, *name_length, null));
            sqltype_name: [32] u8;
            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLColAttribute(stmt, it, SQL_DESC_TYPE_NAME, sqltype_name.data, sqltype_name.count, *name_length, null));
            sqltype_num: int;
            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLColAttribute(stmt, it, SQL_DESC_TYPE, null, SQL_IS_INTEGER, null, *sqltype_num));
            sqltype_concise_num: int;
            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLColAttribute(stmt, it, SQL_DESC_CONCISE_TYPE, null, SQL_IS_INTEGER, null, *sqltype_concise_num));
            log("Column='%' Type='%' typeNum=(%) SQL_DESC_CONCISE_TYPE=(%)\n", to_string(column_name), to_string(sqltype_name), sqltype_num, sqltype_concise_num, flags=.VERY_VERBOSE_ONLY);

            // Find struct_member with same name as the current column
            column_c_name:= to_string(column_name.data);
            found, member:= find_member(T, column_c_name);
            if !found {
                if #complete ignore_unknown == {
                    case .CRASH;
                        log_error("Error at: %\nNo struct member with the name '%' was found.\n", location_to_path(location), column_c_name);
                        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                    case .WARN;
                        log("No struct member with the name '%' was found, skipping..\n", column_c_name, flags=.WARNING);
                        continue;
                    case .SILENT;
                        continue;
                } 
            }

            // Queries the result set data from odbc depending on the found member's type, and saves into the row object 
            member_pointer:= (cast(*void) *temp_data) + member.offset_in_bytes; // pointer to the current member in struct
            if member.type.type == {
                case .INTEGER;
                    info:= cast(*Type_Info_Integer) member.type;
                    member_value :Any;
                    if info.runtime_size == {
                        case 1;
                            if info.signed {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_STINYINT, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*s8)member_pointer;
                            } else {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_UTINYINT, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*u8)member_pointer;
                            }
                        case 2;
                            if info.signed {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_SSHORT, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*s16)member_pointer;
                            } else {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_USHORT, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*u16)member_pointer;
                            }
                        case 4;
                            if info.signed {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_SLONG, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*s32)member_pointer;
                            } else {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_ULONG, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*u32)member_pointer;
                            }
                        case 8;
                            if info.signed {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_SBIGINT, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*s64)member_pointer;
                            } else {
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_UBIGINT, member_pointer, info.runtime_size, *indicator));
                                member_value = <<cast(*u64)member_pointer;
                            }
                        case;
                            log_error("Error at: %\nInteger of runtime size % not supported. Member='%'\n", location_to_path(location), info.runtime_size, member.name);
                            return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                    }
                    array_add(*has_value, indicator != SQL_NULL_DATA);
                    log("Bound INTEGER result to struct member '%'. value=%, runtime_size=%, signed=%\n", member.name, member_value, info.runtime_size, info.signed, flags=.VERY_VERBOSE_ONLY);

                case .STRING;
                    member_string:= cast(*string)member_pointer;
                    if sqltype_num == SQL_CHAR || sqltype_num == SQL_VARCHAR || sqltype_num == SQL_LONGVARCHAR {
                        // NOTE: this does not write to member_string. It just needs to be non-null pointer.
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_CHAR, member_string, 0, *indicator), to_ignore=.[SQL_SUCCESS_WITH_INFO]); // retrieve size

                        if indicator == SQL_NO_TOTAL then assert(false, "SQL_NO_TOTAL not Implemented"); // @incomplete :SQL_NO_TOTAL

                        if indicator > 0 { // only if theres actually data
                            <<member_string = alloc_string(indicator + 1, allocator=result_pool_allocator); // null terminator
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_CHAR, member_string.data, member_string.count, *indicator)); // retrieve data
                            member_string.count -= 1; // null terminator
                        }
                    } else if sqltype_num == SQL_WCHAR || sqltype_num == SQL_WVARCHAR || sqltype_num == SQL_WLONGVARCHAR {
                        // NOTE: this does not write to member_string. It just needs to be non-null pointer.
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, 
                            SQLGetData(stmt, it, SQL_C_WCHAR, member_string, 0, *indicator),
                            to_ignore=int.[SQL_SUCCESS_WITH_INFO]);


                        if indicator > 0 || indicator == SQL_NO_TOTAL { // only if theres actually data
                            // indicator is BYTES received from mssql or SQL_NO_TOTAL.
                            // UTF16 -> UTF8 takes up to 1.5 size
                            // mssql supports max s32 -> 2^31-1 = 2.147.483.647
                            // its UTF16 so we cant fill the last byte -> 2.147.483.646
                            // this means we can have up to 2.147.483.646 / 2 UTF16 characters -> 1.073.741.823
                            // WideCharToMultiByte can only convert up to 2^31-1 bytes
                            // -> 2.147.483.646 = x * 1.5  -> 1.431.655.764 BYTES
                            // Also because of this NVARCHAR(max) can take up to 3.221.225.472 BYTES..

                            // Sizes that are <= this, are buffered on the stack in received in one go. And saved in the pool
                            STACK_BUFFER_CUTOFF_SIZE:: 8000; // 8000 is the cutoff from NVARCHAR to NVARCHAR(MAX)

                            // IF SIZE > STACK_BUFFER_CUTOFF_SIZE or its SQL_NO_TOTAL
                            //
                            // This is the max size that we query from the ODBC data in a single iteration.
                            // 1MB seemed to be the sweetspot for large data. The bigger the better ofcourse,
                            // but the bigger, the more short term memory overhead will be there.
                            // e.g. if we were to query the whole 2.1GB (nvarchar(max)) at once it would keep it in memory
                            // until its converted to UTF8. This can take up to ~3GB. Until then it would 
                            // use up to 5GB in total.. So the tradeoff is short term memory for speed.
                            GET_DATA_BUFFER_SIZE:: 1_048_576;

                            // IF SIZE > STACK_BUFFER_CUTOFF_SIZE or its SQL_NO_TOTAL
                            //
                            // Sizes > this, will be single heap allocations.
                            // Sizes that are <= this, will be on the pool. Why can we not have everything in the pool? 
                            // Well we could. BUT the problem is UTF16 conversion to UTF8. The intermediate data has to be stored.
                            // And because we get the data in chunks, we dont know what the total size after the conversion would be.
                            // For this reason we are using realloc. And realloc is not supported by Pool. So we store it on the heap
                            // and resize it on demand. Now maybe you think but we just could copy it into the pool, or not?
                            // Sure, but this causes the same problem we worked so hard to avoid .. having 5GB of data in ram for a short
                            // time.
                            // To still have the best of both worlds we have POOL_ALLOCATOR_CUTOFF_SIZE, which allows us 
                            // to save all the strings of a certain size into the pool, by copying them.
                            // @incomplete @optimize @investigate: see if we can link it to pool bucket size, :UserOptions
                            POOL_ALLOCATOR_CUTOFF_SIZE:: 1_048_576;

                            // IF SIZE > STACK_BUFFER_CUTOFF_SIZE or its SQL_NO_TOTAL
                            //
                            // Bigger value means less realloc calls, but more left over unused memory.
                            // We do free the unused memory at the end, but it still could spike the consumption
                            // until then.
                            MAX_ALLOCATION_INCREASE_PER_ITERATION:: 500_000_000; // 500 MB

                            #assert(GET_DATA_BUFFER_SIZE > STACK_BUFFER_CUTOFF_SIZE) "GET_DATA_BUFFER_SIZE must be larger than STACK_BUFFER_CUTOFF_SIZE";
                            #assert(GET_DATA_BUFFER_SIZE <= POOL_ALLOCATOR_CUTOFF_SIZE) "POOL_ALLOCATOR_CUTOFF_SIZE must be >= GET_DATA_BUFFER_SIZE";

                            // Fast and cheap version for short strings
                            if indicator != SQL_NO_TOTAL && indicator <= STACK_BUFFER_CUTOFF_SIZE {
                                buffer: [STACK_BUFFER_CUTOFF_SIZE + 2] u8; // null terminator
                                REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_WCHAR, buffer.data, buffer.count, *indicator)); // retrieve data

                                utf8_string, success_conversion:= wide_to_utf8(cast(*u16)buffer.data, allocator=result_pool_allocator);
                                if !success_conversion {
                                    log_error("Error at: %\nAt: %\nUTF8 to wide conversion failed!?\n", location_to_path(location), location_to_path(#location()));
                                    return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                                }

                                <<member_string = utf8_string;
                            } else { // Else we do get the string in parts, and most likely its gonna big a big string.
                                // @optimize: make it be a static buffer
                                utf16_buffer:= NewArray(GET_DATA_BUFFER_SIZE + 2, u8); // null terminator
                                defer array_free(utf16_buffer);

                                // @optimize: make it be a static buffer to start out with, in case the string
                                //           is shorter. :utf8Conversion
                                // @optimize: for known size with indicator and windows api... :utf8Conversion
                                // Count will be total allocated size NOT used size.
                                // We allocate a bigger buffer than above for two reasons.
                                // 1. after the conversion it could expand and
                                // 2. its not unlikely we need more data anways if we end up here
                                utf8_string:= alloc_string(utf16_buffer.count * 2, allocator=context.allocator); // null terminator
                                used_bytes:= 0;
                                
                                old := current_time_monotonic();
                                realloc_time: Apollo_Time;
                                while true {
                                    auto_release_temp();
                                    reset(*temp_string_pool);

                                    success_get_data, return_code:= 
                                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, 
                                            SQLGetData(stmt, it, SQL_C_WCHAR, utf16_buffer.data, utf16_buffer.count, *indicator), 
                                            to_ignore=.[SQL_SUCCESS_WITH_INFO, SQL_NO_DATA]); // retrieve data
                                    
                                    if return_code == SQL_NO_DATA { 
                                        // resize it one last time if its to big .. this can free up to MAX_ALLOCATION_INCREASE_PER_ITERATION - 2 bytes.
                                        utf8_string.data = realloc(utf8_string.data, used_bytes, utf8_string.count, allocator=context.allocator);
                                        utf8_string.count = used_bytes;
                                        break; 
                                    }

                                    //print("indi=%, btr=%, suc=%, rc=%\n", indicator, bytes_to_receive, success_get_data, return_code);

                                    // We dont use temp here because it could be wayyy bigger then the temporary storage. Idealy we'd want it 
                                    // to go into a pre allocated buffer instead of allocation again every iteration ..
                                    // @optimize :utf8Conversion
                                    utf8_temp_string, success_conversion:= wide_to_utf8(cast(*u16)utf16_buffer.data, allocator=temp_string_allocator);
                                    if !success_conversion {
                                        log_error("Error at: %\nAt: %\nUTF8 to wide conversion failed!?\n", location_to_path(location), location_to_path(#location()));
                                        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                                    }

                                    // resize string if needed
                                    if utf8_string.count < used_bytes + utf8_temp_string.count {
                                        new_size:= (utf8_string.count - 2) * 2 + 2; // double, excluding null terminator
                                        new_size = min(new_size, 3_221_225_472); // cap at max size we can receive (2^31 - 1) * 1,5  See description above to why
                                        new_size = min(new_size, utf8_string.count + MAX_ALLOCATION_INCREASE_PER_ITERATION); // cap allocation to minimize overhead

                                        //print("realloc, rc=%, ind=%, size=%, new_size=%, diff=%, free=%, needed=%\n", return_code, indicator, utf8_string.count, new_size, new_size - utf8_string.count, utf8_string.count - used_bytes, used_bytes + utf8_temp_string.count); 

                                        #if DEBUG   old := current_time_monotonic();
                                        utf8_string.data = realloc(utf8_string.data, new_size, utf8_string.count, allocator=context.allocator);
                                        #if DEBUG   now := current_time_monotonic();
                                        #if DEBUG   realloc_time += now - old;
                                        utf8_string.count = new_size;
                                    }
                                    // Copy data utf8 data from utf8_temp_string to utf8_string
                                    assert(utf8_string.count - used_bytes > utf8_temp_string.count); // enough space
                                    memcpy(utf8_string.data + used_bytes, utf8_temp_string.data, utf8_temp_string.count);
                                    used_bytes += utf8_temp_string.count;
                                }
                                #if DEBUG   now := current_time_monotonic();
                                #if DEBUG   log("String query and convesion to UTF8 took % ms of which realloc was % ms\n", to_milliseconds(now - old), to_milliseconds(realloc_time), flags=.VERY_VERBOSE_ONLY);

                                // If its small we save it into the pool. The short term memory overhead for the copy
                                // is 2 * POOL_ALLOCATOR_CUTOFF at most
                                if utf8_string.count <= POOL_ALLOCATOR_CUTOFF_SIZE {
                                    <<member_string = alloc_string(utf8_string.count, allocator=result_pool_allocator); // null terminator
                                    memcpy(member_string.data, utf8_string.data, member_string.count);
                                    free(utf8_string);
                                } else {
                                    array_add(*extra_data_to_free, .{utf8_string.data, context.allocator});
                                    <<member_string = utf8_string;
                                }
                            }
                        }

                    // DATE to STRING conversions 
                    } else if sqltype_num == SQL_DATETIME { // does handle DateTime and SmallDateTime
                        timestamp: TIMESTAMP_STRUCT;
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_TYPE_TIMESTAMP, *timestamp, size_of(TIMESTAMP_STRUCT), *indicator));
                        <<member_string = sprint("%-%-%T%:%:%.%", timestamp.year, formatInt(timestamp.month, minimum_digits=2), 
                                formatInt(timestamp.day, minimum_digits=2), formatInt(timestamp.hour, minimum_digits=2), 
                                formatInt(timestamp.minute, minimum_digits=2), formatInt(timestamp.second, minimum_digits=2), timestamp.fraction,
                                result_allocator=result_pool_allocator, builder_allocator=temp);   
                    } else if sqltype_num == SQL_TYPE_DATE {
                        date: DATE_STRUCT;
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_TYPE_DATE, *date, size_of(DATE_STRUCT), *indicator));
                        <<member_string = sprint("%-%-%", date.year, formatInt(date.month, minimum_digits=2), formatInt(date.day, minimum_digits=2),
                                                result_allocator=result_pool_allocator, builder_allocator=temp);   
                    } else if sqltype_num == -154 { // TIME. SQL_SS_TYPE_TIME2SQL ?
                        // @todo: fractions?
                        time: TIME_STRUCT;
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_TYPE_TIME, *time, size_of(TIME_STRUCT), *indicator));
                        <<member_string = sprint("%:%:%", formatInt(time.hour, minimum_digits=2), formatInt(time.minute, minimum_digits=2), 
                                                formatInt(time.second, minimum_digits=2), result_allocator=result_pool_allocator, builder_allocator=temp);   
                    } else {
                        log_error("Error at: %\nCan not convert '%' to '%'. Member='%' Column='%' sqlTypeNum=(%)\n", location_to_path(location), 
                                    to_string(sqltype_name), member.type.type, member.name, to_string(column_name), sqltype_num);
                        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                    }
                    log("Bound STRING result to struct member '%'. value='%'\n", member.name, <<member_string, flags=.VERY_VERBOSE_ONLY);
                    log("Indicator was: %\n", indicator, flags=.VERY_VERBOSE_ONLY);
                    array_add(*has_value, indicator != SQL_NULL_DATA);

                case .FLOAT;
                    info:= cast(*Type_Info_Float) member.type;
                    member_value :Any;
                    if info.runtime_size == 4 {
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_FLOAT, member_pointer, info.runtime_size, *indicator));
                        member_value = <<cast(*float32)member_pointer;
                    } else if info.runtime_size == 8 {
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_DOUBLE, member_pointer, info.runtime_size, *indicator));
                        member_value = <<cast(*float64)member_pointer;
                    } else {
                        log_error("Error at: %\nFLOAT of runtime size % not supported. Member='%'", location_to_path(location), info.runtime_size, member.name);
                        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                    }
                    log("Bound FLOAT result to struct member '%'. value=%, runtime_size=%\n", member.name, member_value, info.runtime_size, flags=.VERY_VERBOSE_ONLY);
                    array_add(*has_value, indicator != SQL_NULL_DATA);

                case .ARRAY;
                    info:= cast(*Type_Info_Array) member.type;
                    if !(info.element_type.type == .INTEGER && info.element_type.runtime_size == 1) {
                        log_error("Error at: %\nOnly u8 arrays are supported. Member='%'", location_to_path(location), member.name);
                        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                    }

                    if  info.array_type == .FIXED { // inplace array
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_pointer, info.runtime_size, *indicator));
                    } else if info.array_type == .RESIZABLE {
                        member_array:= cast(*[..] u8)member_pointer;
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_pointer, 0, *indicator), to_ignore=.[SQL_SUCCESS_WITH_INFO]); // retrieve size

                        if indicator ==  SQL_NO_TOTAL then assert(false, "SQL_NO_TOTAL Not Implemented");  // @incomplete :SQL_NO_TOTAL

                        if indicator > 0 { // only if theres actually data
                            member_array.allocator = result_pool_allocator;
                            array_reserve(member_array, indicator + 1); // null terminator
                            member_array.count = indicator;
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_array.data, member_array.allocated, *indicator)); // retrieve data
                        }

                    } else if info.array_type == .VIEW{
                        member_array:= cast(*[] u8)member_pointer;
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_pointer, 0, *indicator), to_ignore=.[SQL_SUCCESS_WITH_INFO]); // retrieve size

                        if indicator ==  SQL_NO_TOTAL then assert(false, "SQL_NO_TOTAL Not Implemented");  // @incomplete :SQL_NO_TOTAL

                        if indicator > 0 { // only if theres actually data
                            <<member_array = NewArray(indicator + 1, u8, initialized=false, allocator=result_pool_allocator); // null terminator
                            member_array.count = indicator;
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_array.data, indicator+1, *indicator)); // retrieve data
                        }
                    } else {
                        assert(false); // should never be reached
                    }
                    log("Bound ARRAY result to struct member '%'. bytes=%\n", member.name, indicator, flags=.VERY_VERBOSE_ONLY);
                    log("Indicator was: %\n", indicator, flags=.VERY_VERBOSE_ONLY);
                    array_add(*has_value, indicator != SQL_NULL_DATA);

                case .STRUCT;
                    info:= cast(*Type_Info_Struct) member.type;
                    if info == type_info(Apollo_Time) {
                        member_time:= cast(*Apollo_Time)member_pointer;
                        if sqltype_num == SQL_DATETIME {
                            timestamp: TIMESTAMP_STRUCT;
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_TYPE_TIMESTAMP, *timestamp, size_of(TIMESTAMP_STRUCT), *indicator));
                            if indicator >= 0 {
                                calendar: Calendar_Time = .{timestamp.year, xx (timestamp.month-1), xx (timestamp.day-1), 0, xx timestamp.hour, xx timestamp.minute, xx timestamp.second, 0, 0};
                                calendar_apollo:= calendar_to_apollo(calendar);
                                nano_apollo:= nanoseconds_to_apollo(timestamp.fraction);
                                calendar_apollo += nano_apollo;
                                <<member_time = calendar_apollo;
                            }
                        } else if sqltype_num == SQL_TYPE_DATE {
                            date: DATE_STRUCT;
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_TYPE_DATE, *date, size_of(DATE_STRUCT), *indicator));
                            if indicator >= 0 {
                                calendar: Calendar_Time = .{date.year, xx (date.month-1), xx (date.day-1), 0, 0, 0, 0, 0, 0};
                                <<member_time = calendar_to_apollo(calendar);
                            }
                        } else if sqltype_num == -154 { // TIME. SQL_SS_TYPE_TIME2SQL ?
                            // @todo: fractions?
                            time: TIME_STRUCT;
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_TYPE_TIME, *time, size_of(TIME_STRUCT), *indicator), to_ignore=.[SQL_SUCCESS_WITH_INFO]);
                            if indicator >= 0 {
                                calendar: Calendar_Time = to_calendar(seconds_to_apollo(0));
                                calendar.hour =  xx time.hour;
                                calendar.minute =  xx time.minute;
                                calendar.second =  xx time.second;
                                calendar_apollo:= calendar_to_apollo(calendar);
                                <<member_time = calendar_apollo;
                            }
                        } else {
                            log_error("Error at: %\nConversion from sqltype '%' to struct '%' not supported. Column='%' SqlTypeNum=(%)\n", location_to_path(location), to_string(sqltype_name), info.name, to_string(column_name), sqltype_num);
                            return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                        }
                    } else {
                        log_error("Error at: %\nStruct-Type '%' not supported. Member='%'.\n", location_to_path(location), info.name, member.name);
                        return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
                    }
                    log("Bound result (%) to '%'\n", info.type, member.name, flags=.VERY_VERBOSE_ONLY);
                    log("Indicator was: %\n", indicator, flags=.VERY_VERBOSE_ONLY);
                    array_add(*has_value, indicator != SQL_NULL_DATA);

                case;
                    log_error("Error at: %\nType '%' not supported. Member='%'\n", location_to_path(location), member.type.type, member.name);
                    return false, .{result_pool, extra_data_to_free}, T.[], bool.[], 0;
            }
        }

        log("Row Object: %\n", temp_data, flags=.VERY_VERBOSE_ONLY);
        array_add(*results, temp_data);

        // Free for each column since it could have been 2GB that we free ..
        set_temporary_storage_mark(temporary_storage_mark);
        POOL_LIB.release(*temp_string_pool);

    }

    // Does this still have to unbound with SQLFreeStmt SQL_UNBIND or SQL_RESET_PARAMS ? @investigate
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLCloseCursor(stmt));

    return true, .{result_pool, extra_data_to_free}, results, has_value, row_count;
}

#scope_file
REPORT:: (handle: SQLHANDLE, handle_type: SQLSMALLINT, code: Code, userspace_caller_location: Source_Code_Location, 
                caller_location:= #caller_location, to_ignore: [] int = int.[])  -> (success: bool, return_code: SQLRETURN) #expand {

    return_code: SQLRETURN; /* ODBC API return status */
    return_code = #insert code;

    for to_ignore   if return_code == it then return true, return_code;

    if return_code != SQL_SUCCESS then {
        log("\nAt: %\n", location_to_path(userspace_caller_location), flags=.WARNING);
        handle_diagnostic_record(handle, handle_type, caller_location);
        log("Return Code:%\n", return_code, flags=.WARNING);
    }

    if return_code == SQL_ERROR {
        log_error("SQL call returned an error\n");
        return false, return_code;
    } else if return_code == SQL_INVALID_HANDLE {
        log("SQL call returned an invalid handle\n", flags=.WARNING);
        return false, return_code;
    } else if !SQL_SUCCEEDED(return_code) {
        log_error("SQL call returned error code %\n", return_code);
        return false, return_code;
    }

    return true, return_code;
}

handle_diagnostic_record:: (handle: SQLHANDLE, handle_type: SQLSMALLINT, location:= #caller_location) {
    message_number: SQLSMALLINT;
    native: SQLINTEGER;
    state: [7] u8;
    text: [256] u8;
    length: SQLSMALLINT;
    return_code: SQLRETURN;

    log("At: %\nThe sql driver reported the following diagnostics whilst running:", location_to_path(location), flags=.WARNING);

    while SQL_SUCCEEDED(return_code)
    {
        message_number += 1;
        return_code = SQLGetDiagRec(handle_type, handle, message_number, state.data, *native, text.data, text.count, *length);
        if (SQL_SUCCEEDED(return_code)) {
            log("%:%:%:%\n", to_string(state), message_number, native, to_string(text), flags=.WARNING);
        } else if return_code == SQL_ERROR {
            log_error("(%) SQLGetDiagRec return code: %\n", location_to_path(location), return_code);
        }
    }
}

location_to_path:: inline (location :Source_Code_Location) -> string {
    return tprint("%:%:%", location.fully_pathed_filename, location.line_number, location.character_number);
}

verify_connection:: inline (using connection: *DB_Connection) -> bool {
    return env && dbc && stmt;
}

find_member:: inline ($T: Type, name: string) -> (success: bool, member: Type_Info_Struct_Member) {
    info:= type_info(T);
    found: bool;
    member: Type_Info_Struct_Member;
    for info.members {
        if STRING_LIB.equal_nocase(it.name, name) {
            found = true;
            member = it;
            break;
        }
    }

    return found, member;
}

sprint:: (format_string: string, args: .. Any, result_allocator: Allocator, builder_allocator: Allocator) -> string #must {
    push_allocator(builder_allocator);

    builder: String_Builder;

    print_to_builder(*builder, format_string, ..args);

    return builder_to_string(*builder, allocator=result_allocator);
} @PrintLike