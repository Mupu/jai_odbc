#scope_file
STRING_LIB:: #import "String"; // equal_nocase
#import "Basic";
#import "Windows_Utf8";
#load "generated_windows.jai";

#scope_export
// Export "Pool". User needs to be able to call 'release'
using,only(release) #import "Pool";

// fix big strings
// check ram usage with big strings and mention big string readme if thats happening

// MAKE has_value better!!!!!!!!!!
// TODO parameter counting
// TODO does execute break when this function is called with context.allocator = temp?

// TODO tests for all integer types and long binary/strings, and conversions
// TODO transactions

DB_Connection:: struct {
    env: SQLHENV;
    dbc: SQLHDBC;
    stmt: SQLHSTMT;
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

Unkown_Result_Mode:: enum {
    CRASH;
    WARN;
    SILENT;
}

//
// Wrapper for 'execute' with the difference that it automatically 
// frees the result pool on end of scope(defer).
//
// For more information see notes for 'execute'.
//
EXECUTE:: (using connection: *DB_Connection, $T: Type, command: string, args: .. Any, $ignore_unknown:= Unkown_Result_Mode.CRASH, location:= #caller_location) 
                -> (success: bool, result_set_allocator: Pool #must, results: [] T, has_value: [] bool, modified_rows: int) #expand {

    success, result_set_allocator, results, has_value, modified_rows:= execute(connection, T, command, ..args, ignore_unknown=ignore_unknown, location=location) ;
    `defer release(*result_set_allocator);
    return success, result_set_allocator, results, has_value, modified_rows;
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
    // If this is empty and someone called this with i.e. SELECT it causes a crash since 
    // it will end up calling array_add, which will ultimately call realloc with size 0..
    Dummy:: struct { var: u8;}; 
    // This should technically not allocate anything if called with i.e. DELETE statement, but we free just in case.
    success, result_set_allocator, results, has_value, modified_rows:= execute(connection, Dummy, command, ..args, ignore_unknown=.CRASH, location=location);
    release(*result_set_allocator);
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
                -> (success: bool, result_set_allocator: Pool #must, results: [] T, has_value: [] bool, modified_rows: int) {

    // Clean up temp memory after this call since it could be a lot due to unicode strings
    // Maybe do this on a per-column basis?
    temporary_storage_mark:= get_temporary_storage_mark();
    defer set_temporary_storage_mark(temporary_storage_mark);

    if !verify_connection(connection) {
        log_error("Error at: %\nexecute was called with an invalid connection state\n", location_to_path(location));
        return false, Pool.{}, T.[], bool.[], 0;
    }

    log("**** Running Query ****\nAt %\n", location_to_path(location), flags=.VERBOSE_ONLY);
    log("%\n", command, flags=.VERBOSE_ONLY);

    // Used for the wide string conversions that are long and for small sprint calls.
    temp_string_pool: Pool;
	set_allocators(*temp_string_pool);
    defer release(*temp_string_pool);

    temp_string_allocator: Allocator;
    temp_string_allocator.proc = pool_allocator_proc;
    temp_string_allocator.data = *temp_string_pool;


    // Since the results usually have the same lifespan we use a Pool allocator
    // NOTE: This is freed by the user. It has to be freed even if success is false. 
    // Since this function can return at any point when encountering errors.
    result_pool: Pool;
	set_allocators(*result_pool);

    result_pool_allocator: Allocator;
    result_pool_allocator.proc = pool_allocator_proc;
    result_pool_allocator.data = *result_pool;


    REPORT_MAYBE_RETURN:: (handle: SQLHANDLE, handle_type: SQLSMALLINT, code: Code, library_call_location:= #caller_location) -> success: bool, return_code: SQLRETURN #expand {
        userspace_caller_location:= `location;
        success, return_code:= REPORT(handle, handle_type, code, userspace_caller_location, library_call_location);
        if !success {
            `return false, result_pool, T.[], bool.[], 0;
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
                // SQL_C_U... then? For now we just do this.
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
                        return false, result_pool, T.[], bool.[], 0;
                }

                log("Bound INTEGER to parameter %, value=%, runtime_size=%, signed=%\n", index+1, arg, info.runtime_size, info.signed, flags=.VERY_VERBOSE_ONLY);

            case .STRING;
                arg_casted:= <<cast(*string) arg.value_pointer;
                allocator:= ifx arg_casted.count > 2048 then temp_string_allocator else temp;
                // Data needs to live until SQLExecute is called
                string_wide, success, string_byte_length:= utf8_to_wide(arg_casted, allocator=allocator);
                if !success {
                    log_error("Error at: %\nAt: %\nUTF8 to wide conversion failed!?\n", location_to_path(location), location_to_path(#location()));
                    return false, result_pool, T.[], bool.[], 0;
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
                    return false, result_pool, T.[], bool.[], 0;
                }
                log("Bound FLOAT to parameter %, value=%\n", index+1, arg, flags=.VERY_VERBOSE_ONLY);
            case .ARRAY;
                info:= cast(*Type_Info_Array) arg.type;
                if !(info.element_type.type == .INTEGER && info.element_type.runtime_size == 1) {
                    log_error("Error at: %\nOnly ARRAY of type 'u8' are supported. Argumet=%\n", location_to_path(location), index+1);
                    return false, result_pool, T.[], bool.[], 0;
                }

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
                    return false, result_pool, T.[], bool.[], 0;
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
                return false, result_pool, T.[], bool.[], 0;
        }
    }

    //
    // Execute
    //
    command_wide, command_bool, command_byte_length:= utf8_to_wide(command, allocator=temp);
    if !command_bool {
        log_error("Error at: %\nAt: %\nUTF8 to wide conversion failed!?\n", location_to_path(location), location_to_path(#location()));
        return false, result_pool, T.[], bool.[], 0;
    }
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLExecDirectW(stmt, command_wide, command_byte_length/2));

    // Free temp storage and temp_string_pool, since unicode strings could have used a lot.
    // It should be save to do here, since SQLExcelDirectW uses all bound buffers and indicators of SQLBindParameters.
    // https://learn.microsoft.com/en-us/sql/odbc/reference/develop-app/deferred-buffers?view=sql-server-ver16
    set_temporary_storage_mark(temporary_storage_mark);
    release(*temp_string_pool);

    //
    // Retrieve and parse the result's data
    //
    column_count: u16;
    row_count: s64;
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLNumResultCols(stmt, xx *column_count));
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLRowCount(stmt, *row_count));
    row_count = max(0, row_count); // Its -1 i.e. if it was a SELECT query

    log("Query Result: % columns, % modified rows\n", column_count, row_count, flags=.VERBOSE_ONLY);

    if !column_count then return true, result_pool, T.[], bool.[], row_count; // no data to query

    results: [..] T;
    results.allocator = result_pool_allocator;

    has_value :[..] bool;
    has_value.allocator = result_pool_allocator;

    indicator: int;
    while true { // For all rows in result set
        temp_data: T; // Its in here so its get reset to defaults every row.

        // Fetch single row
        success, fetch_result:= REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLFetch(stmt));
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
                        return false, result_pool, T.[], bool.[], 0;
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
                            return false, result_pool, T.[], bool.[], 0;
                    }
                    array_add(*has_value, indicator != SQL_NULL_DATA);
                    log("Bound INTEGER result to struct member '%'. value=%, runtime_size=%, signed=%\n", member.name, member_value, info.runtime_size, info.signed, flags=.VERY_VERBOSE_ONLY);

                case .STRING;
                    member_string:= cast(*string)member_pointer;
                    if sqltype_num == SQL_CHAR || sqltype_num == SQL_VARCHAR || sqltype_num == SQL_LONGVARCHAR {
                        // NOTE: this does not write to member_string. It just needs to be non-null pointer.
                        SQLGetData(stmt, it, SQL_C_CHAR, member_string, 0, *indicator); // retrieve size

                        if indicator == SQL_NO_TOTAL then assert(false, "SQL_NO_TOTAL not Implemented");

                        if indicator > 0 { // only if theres actually data
                            <<member_string = alloc_string(indicator + 1, result_pool_allocator); // null terminator
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_CHAR, member_string.data, member_string.count, *indicator)); // retrieve data
                            member_string.count -= 1; // null terminator
                        }
                    } else if sqltype_num == SQL_WCHAR || sqltype_num == SQL_WVARCHAR || sqltype_num == SQL_WLONGVARCHAR {
                        // NOTE: this does not write to member_string. It just needs to be non-null pointer.
                        SQLGetData(stmt, it, SQL_C_WCHAR, member_string, 0, *indicator); // should not write to member_string, retrieve size

                        if indicator == SQL_NO_TOTAL then assert(false, "SQL_NO_TOTAL not Implemented");

                        if indicator > 0 { // only if theres actually data
                            allocator:= ifx indicator > 2048 then temp_string_allocator else temp;
                            temp_string:= alloc_string(indicator + 2, allocator=allocator); // null terminator
                            success:= REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_WCHAR, temp_string.data, temp_string.count, *indicator)); // retrieve data
                            
                            <<member_string, success = wide_to_utf8(cast(*u16)temp_string.data, allocator=result_pool_allocator);
                            if !success {
                                log_error("Error at: %\nAt: %\nUTF8 to wide conversion failed!?\n", location_to_path(location), location_to_path(#location()));
                                return false, result_pool, T.[], bool.[], 0;
                            }
                        }

                    // DATE to STRING conversions 
                    } else if sqltype_num == SQL_DATETIME { // does handle DateTime and SmallDateTime
                        timestamp: TIMESTAMP_STRUCT;
                        SQLGetData(stmt, it, SQL_C_TYPE_TIMESTAMP, *timestamp, size_of(TIMESTAMP_STRUCT), *indicator);
                        <<member_string = sprint("%-%-%T%:%:%.%", timestamp.year, formatInt(timestamp.month, minimum_digits=2), 
                                formatInt(timestamp.day, minimum_digits=2), formatInt(timestamp.hour, minimum_digits=2), 
                                formatInt(timestamp.minute, minimum_digits=2), formatInt(timestamp.second, minimum_digits=2), timestamp.fraction,
                                result_allocator=result_pool_allocator, builder_allocator=temp);   
                    } else if sqltype_num == SQL_TYPE_DATE {
                        date: DATE_STRUCT;
                        SQLGetData(stmt, it, SQL_C_TYPE_DATE, *date, size_of(DATE_STRUCT), *indicator);
                        <<member_string = sprint("%-%-%", date.year, formatInt(date.month, minimum_digits=2), formatInt(date.day, minimum_digits=2),
                                                result_allocator=result_pool_allocator, builder_allocator=temp);   
                    } else if sqltype_num == -154 { // TIME. SQL_SS_TYPE_TIME2SQL ?
                        // TODO fractions?
                        time: TIME_STRUCT;
                        SQLGetData(stmt, it, SQL_C_TYPE_TIME, *time, size_of(TIME_STRUCT), *indicator);
                        <<member_string = sprint("%:%:%", formatInt(time.hour, minimum_digits=2), formatInt(time.minute, minimum_digits=2), 
                                                formatInt(time.second, minimum_digits=2), result_allocator=result_pool_allocator, builder_allocator=temp);   
                    } else {
                        log_error("Error at: %\nCan not convert '%' to '%'. Member='%' Column='%' sqlTypeNum=(%)\n", location_to_path(location), 
                                    to_string(sqltype_name), member.type.type, member.name, to_string(column_name), sqltype_num);
                        return false, result_pool, T.[], bool.[], 0;
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
                        return false, result_pool, T.[], bool.[], 0;
                    }
                    log("Bound FLOAT result to struct member '%'. value=%, runtime_size=%\n", member.name, member_value, info.runtime_size, flags=.VERY_VERBOSE_ONLY);
                    array_add(*has_value, indicator != SQL_NULL_DATA);

                case .ARRAY;
                    info:= cast(*Type_Info_Array) member.type;
                    if !(info.element_type.type == .INTEGER && info.element_type.runtime_size == 1) {
                        log_error("Error at: %\nOnly u8 arrays are supported. Member='%'", location_to_path(location), member.name);
                        return false, result_pool, T.[], bool.[], 0;
                    }

                    if  info.array_type == .FIXED { // inplace array
                        REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_pointer, info.runtime_size, *indicator));
                    } else if info.array_type == .RESIZABLE {
                        member_array:= cast(*[..] u8)member_pointer;
                        SQLGetData(stmt, it, SQL_C_BINARY, member_pointer, 0, *indicator); // retrieve size

                        if indicator ==  SQL_NO_TOTAL then assert(false, "Not Implemented");

                        if indicator > 0 { // only if theres actually data
                            member_array.allocator = result_pool_allocator;
                            array_reserve(member_array, indicator + 1); // null terminator
                            member_array.count = indicator;
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_array.data, member_array.allocated, *indicator)); // retrieve data
                        }

                    } else {
                        member_array:= cast(*[] u8)member_pointer;
                        SQLGetData(stmt, it, SQL_C_BINARY, member_pointer, 0, *indicator); // retrieve size

                        if indicator ==  SQL_NO_TOTAL then assert(false, "Not Implemented");

                        if indicator > 0 { // only if theres actually data
                            <<member_array = NewArray(indicator + 1, u8, initialized=false, allocator=result_pool_allocator); // null terminator
                            member_array.count = indicator;
                            REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLGetData(stmt, it, SQL_C_BINARY, member_array.data, indicator+1, *indicator)); // retrieve data
                        }
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
                            SQLGetData(stmt, it, SQL_C_TYPE_TIMESTAMP, *timestamp, size_of(TIMESTAMP_STRUCT), *indicator);
                            if indicator >= 0 {
                                calendar: Calendar_Time = .{timestamp.year, xx (timestamp.month-1), xx (timestamp.day-1), 0, xx timestamp.hour, xx timestamp.minute, xx timestamp.second, 0, 0};
                                calendar_apollo:= calendar_to_apollo(calendar);
                                nano_apollo:= nanoseconds_to_apollo(timestamp.fraction);
                                calendar_apollo += nano_apollo;
                                <<member_time = calendar_apollo;
                            }
                        } else if sqltype_num == SQL_TYPE_DATE {
                            date: DATE_STRUCT;
                            SQLGetData(stmt, it, SQL_C_TYPE_DATE, *date, size_of(DATE_STRUCT), *indicator);
                            if indicator >= 0 {
                                calendar: Calendar_Time = .{date.year, xx (date.month-1), xx (date.day-1), 0, 0, 0, 0, 0, 0};
                                <<member_time = calendar_to_apollo(calendar);
                            }
                        } else if sqltype_num == -154 { // TIME. SQL_SS_TYPE_TIME2SQL ?
                            // TODO fractions?
                            time: TIME_STRUCT;
                            SQLGetData(stmt, it, SQL_C_TYPE_TIME, *time, size_of(TIME_STRUCT), *indicator);
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
                            return false, result_pool, T.[], bool.[], 0;
                        }
                    } else {
                        log_error("Error at: %\nStruct-Type '%' not supported. Member='%'.\n", location_to_path(location), info.name, member.name);
                        return false, result_pool, T.[], bool.[], 0;
                    }
                    log("Bound result (%) to '%'\n", info.type, member.name, flags=.VERY_VERBOSE_ONLY);
                    log("Indicator was: %\n", indicator, flags=.VERY_VERBOSE_ONLY);
                    array_add(*has_value, indicator != SQL_NULL_DATA);

                case;
                    log_error("Error at: %\nType '%' not supported. Member='%'\n", location_to_path(location), member.type.type, member.name);
                    return false, result_pool, T.[], bool.[], 0;
            }
        }

        log("Row Object: %\n", temp_data, flags=.VERY_VERBOSE_ONLY);
        array_add(*results, temp_data);

        // Free for each column since it could have been 2GB that we free ..
        set_temporary_storage_mark(temporary_storage_mark);
        release(*temp_string_pool);

    }

    // Does this still have to unbound with SQLFreeStmt SQL_UNBIND or SQL_RESET_PARAMS ?
    REPORT_MAYBE_RETURN(stmt, SQL_HANDLE_STMT, SQLCloseCursor(stmt));

    return true, result_pool, results, has_value, row_count;
}

#scope_file
REPORT:: (handle: SQLHANDLE, handle_type: SQLSMALLINT, code: Code, userspace_caller_location: Source_Code_Location, caller_location:= #caller_location) 
            -> (success: bool, return_code: SQLRETURN) #expand {

    return_code: SQLRETURN; /* ODBC API return status */
    return_code = #insert code;

    if return_code == SQL_NO_DATA then return true, return_code;

    if return_code != SQL_SUCCESS then {
        log("At: %\n", location_to_path(userspace_caller_location), flags=.WARNING);
        handle_diagnostic_record(handle, handle_type, caller_location);
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

    log("At: %\nThe sql driver reported the following diagnostics whilst running", location_to_path(location), flags=.WARNING);

    while SQL_SUCCEEDED(return_code)
    {
        message_number += 1;
        return_code = SQLGetDiagRec(handle_type, handle, message_number, state.data, *native, text.data, text.count, *length);
        if (SQL_SUCCEEDED(return_code)) {
            log("\n%:%:%:%\n", to_string(state), message_number, native, to_string(text), flags=.WARNING);
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