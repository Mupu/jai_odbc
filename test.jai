#import,file "jai_odbc.jai";
#import "Basic"()(MEMORY_DEBUGGER=DEBUG);
DEBUG_LIB:: #import "Debug";

DEBUG:: false;
SQL_CONNECTION_STRING:: "Driver={SQL Server Native Client 11.0};Server=MUPU;Database=Test;Trusted_Connection=Yes;";

//#import "Project_Generator";
//#run Project_Generator.build(#file);

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

#run main();
main:: () {
    DEBUG_LIB.init();
    context.print_style.struct_printer = apollo_struct_printer;
    context.logger = test_logger;
    context.log_level = .VERY_VERBOSE;
    //context.log_level = .VERBOSE;
    //context.log_level = .NORMAL;

    defer p(<<context.temporary_storage);
    #if DEBUG defer report_memory_leaks();

    query_driver();
    querry_datasources();
    connection_test();
    query_test();
    db_test();


    if false
    { 
        p(<<context.temporary_storage);
        new_context := context;  // Copy all values from Context.
        new_context.allocator = temp;

        //push_context new_context 
        {
            state, connection_success:= connect(SQL_CONNECTION_STRING);
            assert(connection_success);
            defer disconnect(*state);
            p(<<context.temporary_storage);

            if true
            {
                Dummy:: struct {
                    testVal: string;
                }
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testString as testVal FROM Test; UPDATE Test SET testString = 'hi';");
                defer release(*result_set_allocator);
                assert(success);
            }
            p(<<context.temporary_storage);
            insertval:= u8.[4];
            sqltype:= "testBinary";
            jaitype:: [..] u8;
            {
                success, rows:= execute(*state, tprint("UPDATE Test SET % = ?;", sqltype), insertval);
                assert(success);
            }
            {
                Dummy:: struct {
                    testVal: jaitype;
                }
                success, result_set_allocator, results, has_value, rows:= EXECUTE(*state, JaiTest, "SELECT testBinary, testDouble FROM [Test]");
                assert(success);
                p(results, has_value);
            }
            p(<<context.temporary_storage);
        }
    }

}

apollo_struct_printer:: (builder: *String_Builder, any: Any, user_data: *void) -> bool {
    ti:= any.type;
    if ti == type_info(Apollo_Time) {
        v:= cast(*Apollo_Time) any.value_pointer;
        if v != APOLLO_TIME_INVALID then 
            print_to_builder(builder, "%,{ %, % }", calendar_to_iso_string(to_calendar(v)), v.low, v.high);
        else
            print_to_builder(builder, "INVALID");
        return true;
    }

    return false;
}

test_logger:: (message: string, data: *void, info: Log_Info) {
    #import "Print_Color";
    if !message then return;
    if (info.common_flags & (Log_Flags.CONTENT | .TO_FILE_ONLY)) != 0 then assert(false); // Dont support files & content
   
    // Dont print if log_level to low
    if context.log_level == {
        case .NORMAL; 
            if (info.common_flags & (Log_Flags.VERBOSE_ONLY | .VERY_VERBOSE_ONLY)) != 0 then return;

        case. VERBOSE;  
            if (info.common_flags & Log_Flags.VERY_VERBOSE_ONLY) != 0 then return;
    }

    to_standard_error:= (info.common_flags & .ERROR) != 0;

    color: Console_Color;
    if info.common_flags == {
        case .ERROR; color = .RED;
        case .WARNING; color = .YELLOW;
        case .NONE; color = .WHITE;
        case .VERBOSE_ONLY; color = .CYAN;
        case .VERY_VERBOSE_ONLY; color = .BLUE;

        case .CONTENT; color = .WHITE;
        case .TO_FILE_ONLY; color = .WHITE;
    }

    if message[message.count-1] != #char "\n" {
        print_color("%\n", message, color=color, to_standard_error=to_standard_error);
    } else {
        print_color("%", message, color=color, to_standard_error=to_standard_error);
    }
}

JaiTest:: struct {
    testString:     string;
    testStringN:    string;
    testStringMax:  string;
    testStringNMax: string;
    testStringC:    string;
    testStringNC:   string;

    testInt:    s32;
    testFloat:  float;
    testDouble: float64;

    testBinary:     [] u8;
    testVarBinary:  [] u8;
    
    testDate:           Apollo_Time = APOLLO_TIME_INVALID;
    testTime:           Apollo_Time = APOLLO_TIME_INVALID;
    testDateTime:       Apollo_Time = APOLLO_TIME_INVALID;
    testSmallDateTime:  Apollo_Time = APOLLO_TIME_INVALID;
}

db_test:: () {
    operator ==:: inline (a: JaiTest, b: JaiTest) -> bool {
        if a.testString != b.testString then return false;
        if a.testStringN != b.testStringN then return false;
        if a.testStringMax != b.testStringMax then return false;
        if a.testStringNMax != b.testStringNMax then return false;
        if a.testStringC != b.testStringC then return false;
        if a.testStringNC != b.testStringNC then return false;

        if a.testInt != b.testInt then return false;
        if a.testFloat != b.testFloat then return false;
        if a.testDouble != b.testDouble then return false;

        if a.testBinary.count != b.testBinary.count || memcmp(a.testBinary.data, b.testBinary.data, a.testBinary.count) != 0 then return false;
        if a.testVarBinary.count != b.testVarBinary.count || memcmp(a.testVarBinary.data, b.testVarBinary.data, a.testVarBinary.count) != 0 then return false;

        if a.testDate != b.testDate then return false;
        if a.testTime != b.testTime then return false;
        if a.testDateTime != b.testDateTime then return false;
        if a.testSmallDateTime != b.testSmallDateTime then return false;

        return true;
    }

    //s, success:= connect(SQL_CONNECTION_STRING);
    state, connection_success:= connect(SQL_CONNECTION_STRING);
    //s, success:= connect(SQL_CONNECTION_STRING);
    assert(connection_success);
    log("Connected\n\n");

    defer { 
        disconnect(*state);
        log("\nDisconnected\n");
    }

    //
    // Setup Table
    //

    // Drops the Table and Recreates it with default entries
    setup_table:: (state: DB_Connection) {
        // Drop if Exists
        success, rows:= execute(*state, "IF OBJECT_ID(N'dbo.Test', N'U') IS NOT NULL DROP TABLE [dbo].[Test]");
        assert(success);

        CREATE_TABLE:: #string DONE
            CREATE TABLE [dbo].[Test](
                [testString] [varchar](10) NULL,
                [testStringN] [nvarchar](10) NULL,
                [testStringMax] [varchar](max) NULL,
                [testStringNMax] [nvarchar](max) NULL,
                [testStringC] [char](10) NULL,
                [testStringNC] [nchar](10) NULL,
                [testInt] [int] NULL,
                [testFloat] [real] NULL,
                [testDouble] [float] NULL,
                [testBinary] [binary](8) NULL,
                [testVarBinary] [varbinary](10) NULL,
                [testDate] [date] NULL,
                [testTime] [time](7) NULL,
                [testDateTime] [datetime] NULL,
                [testSmallDateTime] [smalldatetime] NULL,
            ) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
        DONE
        success, rows = execute(*state, CREATE_TABLE);
        assert(success);

        TEST_DATA:: #string DONE
            INSERT INTO [dbo].[Test]
                ([testString]
                ,[testStringN]
                ,[testStringMax]
                ,[testStringNMax]
                ,[testStringC]
                ,[testStringNC]
                ,[testInt]
                ,[testFloat]
                ,[testDouble]
                ,[testBinary]
                ,[testVarBinary]
                ,[testDate]
                ,[testTime]
                ,[testDateTime]
                ,[testSmallDateTime])
            VALUES
                ('0123456789', N'画画画画画', 'LOOOOOOOOOOOONG', N'画画画画画画画画画画画画画画画', 'short', N'short画', 5, 6.6666666, 7.66666666666666666, 0x10002,
                    0x20004, '2022-12-17T14:35:38.777Z', '2022-12-17T14:35:38.777Z', '2022-12-17T14:35:38.777Z', '2022-12-17T14:35:38.777Z'),
                (NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        DONE
        success, rows = execute(*state, TEST_DATA);
        assert(success);
        assert(rows == 2);

    }

    //
    // Test Select
    //
    {
        setup_table(state);
        {
            success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT * FROM [Test] where testString is not null");
            defer release(*result_set_allocator);
            assert(success);
            assert(rows == 0);
            assert(results.count == 1, "Was %", results.count);

            for has_value assert(it);

            expected:= JaiTest.{
                testString = "0123456789",
                testStringN = "画画画画画",
                testStringMax = "LOOOOOOOOOOOONG",
                testStringNMax = "画画画画画画画画画画画画画画画",
                testStringC = "short     ",
                testStringNC = "short画    ",

                testInt = 5,
                testFloat = 6.6666666,
                testDouble = 7.66666666666666666,

                testBinary = u8.[1, 0, 2, 0, 0, 0, 0, 0],
                testVarBinary = u8.[2, 0, 4],
                
                testDate = .{12921961453107052544, 91366},
                testTime = .{16372488147419103232, -2},
                testDateTime = .{10120506231978397696, 91369},
                testSmallDateTime = .{10141729231978397696, 91369},
            };
            assert (results[0] == expected);
        }

        {
            success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT * FROM [Test] where testString is null");
            defer release(*result_set_allocator);
            assert(success);
            assert(rows == 0);
            assert(results.count == 1);

            for has_value assert(!it);
        }
    }

    //
    // Test Update
    //
    {
        // All Null
        {
            setup_table(state);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, #string DONE 
                    UPDATE [Test] SET [testString] = null
                    ,[testStringN] = null
                    ,[testStringMax] = null
                    ,[testStringNMax] = null
                    ,[testStringC] = null
                    ,[testStringNC] = null
                    ,[testInt] = null
                    ,[testFloat] = null
                    ,[testDouble] = null
                    ,[testBinary] = null
                    ,[testVarBinary] = null
                    ,[testDate] = null
                    ,[testTime] = null
                    ,[testDateTime] = null
                    ,[testSmallDateTime] = null
                    WHERE testString = '0123456789'
                DONE);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);

                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT TOP 1 * FROM [Test]");
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);

                for has_value assert(!it);
            }
        }
        
        // varchar
        {
            setup_table(state);
            var:= "working";
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testString = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testString FROM [Test] WHERE testString = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testString;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // nvarchar
        {
            setup_table(state);
            var:= "画";
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testStringN = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testStringN FROM [Test] WHERE testStringN = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testStringN;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }
        
        // varchar(Max)
        {
            setup_table(state);
            var:= "working";
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testStringMax = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testStringMax FROM [Test] WHERE testStringMax = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testStringMax;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // nvarchar(Max)
        {
            setup_table(state);
            var:= "画";
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testStringNMax = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testStringNMax FROM [Test] WHERE testStringNMax = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testStringNMax;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // char(10)
        {
            setup_table(state);
            var:= "working   ";
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testStringC = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testStringC FROM [Test] WHERE testStringC = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testStringC;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // nchar(10)
        {
            setup_table(state);
            var:= "画         ";
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testStringNC = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testStringNC FROM [Test] WHERE testStringNC = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testStringNC;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // Integer
        {
            setup_table(state);
            var :s32= -255;
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testInt = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testInt FROM [Test] WHERE testInt = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testInt;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // Float
        {
            setup_table(state);
            var:= 42.42;
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testFloat = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testFloat FROM [Test] WHERE testFloat = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testFloat;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // Double
        {
            setup_table(state);
            var:= 42.8888888888888888888;
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testDouble = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testDouble FROM [Test] WHERE testDouble = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testDouble;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // binary(8)
        {
            // Fixed array
            {
                Dummy:: struct {
                    testBinary: [8] u8;
                }
                setup_table(state);
                var:= u8.[4,2,0,0,0,0,0,1];
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testBinary = ? WHERE testString IS NULL", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 1);
                    for has_value assert(!it);
                }
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testBinary FROM [Test] WHERE testBinary = ?", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 0);
                    assert(results.count == 1);
                    for has_value assert(it);
                    result:= results[0].testBinary;
                    assert(memcmp(var.data, result.data, 8) == 0, "\nGot     :%\nExpected:%", result, var);
                }
            }

            // Array View
            {
                Dummy:: struct {
                    testBinary: [] u8;
                }
                setup_table(state);
                var:= NewArray(8, u8);
                defer array_free(var);
                var[0] = 4;
                var[1] = 2;
                var[7] = 2;
                
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testBinary = ? WHERE testString IS NULL", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 1);
                    for has_value assert(!it);
                }
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testBinary FROM [Test] WHERE testBinary = ?", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 0);
                    assert(results.count == 1);
                    for has_value assert(it);
                    result:= results[0].testBinary;
                    assert(memcmp(var.data, result.data, 8) == 0, "\nGot     :%\nExpected:%", result, var);
                }
            }

            // Dynamic Array
            {
                Dummy:: struct {
                    testBinary: [..] u8;
                }
                setup_table(state);
                var : [..]u8;
                array_add(*var, 4, 1, 0, 0, 0, 0, 0, 3);
                defer array_free(var);
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testBinary = ? WHERE testString IS NULL", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 1);
                    for has_value assert(!it);
                }
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testBinary FROM [Test] WHERE testBinary = ?", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 0);
                    assert(results.count == 1);
                    for has_value assert(it);
                    result:= results[0].testBinary;
                    assert(memcmp(var.data, result.data, 8) == 0, "\nGot     :%\nExpected:%", result, var);
                }
            }
        }

        // varbinary(8)
        {
            // Fixed array
            {
                Dummy:: struct {
                    testVarBinary: [8] u8;
                }
                setup_table(state);
                var:= u8.[4,2,0,0,0,0,0,1];
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testVarBinary = ? WHERE testString IS NULL", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 1);
                    for has_value assert(!it);
                }
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testVarBinary FROM [Test] WHERE testVarBinary = ?", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 0);
                    assert(results.count == 1);
                    for has_value assert(it);
                    result:= results[0].testVarBinary;
                    assert(memcmp(var.data, result.data, 8) == 0, "\nGot     :%\nExpected:%", result, var);
                }
            }

            // Array View
            {
                Dummy:: struct {
                    testVarBinary: [] u8;
                }
                setup_table(state);
                var:= NewArray(8, u8);
                defer array_free(var);
                var[0] = 4;
                var[1] = 2;
                var[7] = 2;
                
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testVarBinary = ? WHERE testString IS NULL", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 1);
                    for has_value assert(!it);
                }
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testVarBinary FROM [Test] WHERE testVarBinary = ?", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 0);
                    assert(results.count == 1);
                    for has_value assert(it);
                    result:= results[0].testVarBinary;
                    assert(memcmp(var.data, result.data, 8) == 0, "\nGot     :%\nExpected:%", result, var);
                }
            }

            // Dynamic Array
            {
                Dummy:: struct {
                    testVarBinary: [..] u8;
                }
                setup_table(state);
                var : [..]u8;
                array_add(*var, 4, 1, 0, 0, 0, 0, 0, 3);
                defer array_free(var);
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testVarBinary = ? WHERE testString IS NULL", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 1);
                    for has_value assert(!it);
                }
                {
                    success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testVarBinary FROM [Test] WHERE testVarBinary = ?", var);
                    defer release(*result_set_allocator);
                    assert(success);
                    assert(rows == 0);
                    assert(results.count == 1);
                    for has_value assert(it);
                    result:= results[0].testVarBinary;
                    assert(memcmp(var.data, result.data, 8) == 0, "\nGot     :%\nExpected:%", result, var);
                }
            }
        }
        
    }

    // Date
    {
        // ApolloTime
        {
            setup_table(state);
            calendar : Calendar_Time = .{2022, 11, 17, 0, 0, 0, 0, 0, 0};
            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testDate = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testDate FROM [Test] WHERE testDate = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testDate;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // String
        {
            Dummy:: struct {
                testDate: string;
            }
            setup_table(state);
            calendar : Calendar_Time = .{2022, 6, 4, 0, 0, 0, 0, 0, 0};
            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testDate = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testDate FROM [Test] WHERE testDate = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testDate;
                expected:= "2022-07-05";
                assert(result == expected, "\nGot     :%\nExpected:%", result, expected);
            }
        }
    }

    // Time
    {
        // ApolloTime
        {
            setup_table(state);
            calendar : Calendar_Time = to_calendar(seconds_to_apollo(0));
            calendar.hour =  7;
            calendar.minute =  2;
            calendar.second =  30;
            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testTime = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testTime FROM [Test] WHERE testTime = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testTime;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // String
        {
            Dummy:: struct {
                testTime: string;
            }
            setup_table(state);
            calendar : Calendar_Time = to_calendar(seconds_to_apollo(0));
            calendar.hour =  7;
            calendar.minute =  2;
            calendar.second =  7;
            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testTime = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testTime FROM [Test] WHERE testTime = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testTime;
                expected:= "07:02:07";
                assert(result == expected, "\nGot     :%\nExpected:%", result, expected);
            }
        }
    }

    // datetime
    {
        // ApolloTime
        {
            setup_table(state);
            calendar : Calendar_Time = .{2042, 10, 15, 0, 17, 17, 17, 660, 0};
            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testDateTime = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testDateTime FROM [Test] WHERE testDateTime = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testDateTime;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // String
        {
            Dummy:: struct {
                testDateTime: string;
            }
            setup_table(state);
            calendar : Calendar_Time = .{2042, 10, 15, 0, 4, 5, 6, 660, 0};

            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testDateTime = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testDateTime FROM [Test] WHERE testDateTime = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testDateTime;
                expected:= "2042-11-16T04:05:06.660000000";
                assert(result == expected, "\nGot     :%\nExpected:%", result, expected);
            }
        }
    }

    // smalldatetime
    {
        // ApolloTime
        {
            setup_table(state);
            calendar : Calendar_Time = .{2060, 5, 2, 0, 6, 6, 0, 0, 0};
            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "UPDATE [Test] SET testSmallDateTime = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, JaiTest, "SELECT testSmallDateTime FROM [Test] WHERE testSmallDateTime = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testSmallDateTime;
                assert(result == var, "\nGot     :%\nExpected:%", result, var);
            }
        }

        // String
        {
            Dummy:: struct {
                testSmallDateTime: string;
            }
            setup_table(state);
            calendar : Calendar_Time = .{2061, 5, 2, 0, 7, 7, 7, 760, 0};
            var:= calendar_to_apollo(calendar);
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "UPDATE [Test] SET testSmallDateTime = ? WHERE testString IS NULL", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(success);
                assert(rows == 1);
                for has_value assert(!it);
            }
            {
                success, result_set_allocator, results, has_value, rows:= execute(*state, Dummy, "SELECT testSmallDateTime FROM [Test] WHERE testSmallDateTime = ?", var);
                defer release(*result_set_allocator);
                assert(success);
                assert(success);
                assert(rows == 0);
                assert(results.count == 1);
                for has_value assert(it);
                result:= results[0].testSmallDateTime;
                expected:= "2061-06-03T07:07:00.0";
                assert(result == expected, "\nGot     :%\nExpected:%", result, expected);

            }
        }
    }

    log("**** TESTS PASSED *****");
}


//
// Code below is not updated to match style of READEME
//

query_test:: () {
    print("####### TEST QUERY ######\n");
    env: SQLHENV;
    dbc: SQLHDBC;
    stmt: SQLHSTMT;
    ret: SQLRETURN; /* ODBC API return status */

    /* Allocate an environment handle */
    SQLAllocHandle(SQL_HANDLE_ENV, xx SQL_NULL_HANDLE, *env);
    /* We want ODBC 3 support */
    SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, cast(*void) SQL_OV_ODBC3, 0);
    /* Allocate a connection handle */
    SQLAllocHandle(SQL_HANDLE_DBC, env, *dbc);
    /* Connect to the DSN mydsn */
    /* You will need to change mydsn to one you have created and tested */
    ret = SQLDriverConnect(dbc, null, SQL_CONNECTION_STRING, SQL_NTS,
                    null, 0, null, SQL_DRIVER_NOPROMPT);
    if !SQL_SUCCEEDED(ret) {
        extract_error(dbc, SQL_HANDLE_DBC);
        return;
    }
    /* Allocate a statement handle */
    SQLAllocHandle(SQL_HANDLE_STMT, dbc, *stmt);

    /* Retrieve a list of tables */
    //SQLTables(stmt, null, 0, null, 0, null, 0, "TABLE", SQL_NTS);
    ret = SQLExecDirect(stmt, "SELECT [testString],[testInt] FROM [Test]", SQL_NTS);
    if (!ret) then extract_error(stmt, SQL_HANDLE_STMT);

    columns: SQLSMALLINT; /* number of columns in result-set */
    row:= 0;
    /* How many columns are there */
    SQLNumResultCols(stmt, *columns);
    /* Loop through the rows in the result-set */
    while SQL_SUCCEEDED(ret) {
        ret = SQLFetch(stmt);
        print("Row %\n", row);
        row += 1;
        /* Loop through the columns */
        i : SQLUSMALLINT = 1;
        for i..cast(u16)columns {
            indicator: SQLLEN;
            buf: [512] u8;
            /* retrieve column data as a string */
            ret = SQLGetData(stmt, it, SQL_C_CHAR,
                            buf.data, buf.count, *indicator);
            if (SQL_SUCCEEDED(ret)) {
                /* Handle null columns */
                if (indicator == SQL_NULL_DATA) memcpy(buf.data, "NULL".data, 5);
                print("  Column % : %\n", it, to_string(buf.data));
            }
        }
    }
}

connection_test:: () {
    print("####### TEST ######\n");
    env: SQLHENV;
    dbc: SQLHDBC;
    stmt: SQLHSTMT;
    ret: SQLRETURN; /* ODBC API return status */
    columns: SQLSMALLINT; /* number of columns in result-set */
    row:= 0;

    /* Allocate an environment handle */
    SQLAllocHandle(SQL_HANDLE_ENV, xx SQL_NULL_HANDLE, *env);
    /* We want ODBC 3 support */
    SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, cast(*void) SQL_OV_ODBC3, 0);
    /* Allocate a connection handle */
    SQLAllocHandle(SQL_HANDLE_DBC, env, *dbc);
    /* Connect to the DSN mydsn */
    /* You will need to change mydsn to one you have created and tested */
    ret = SQLDriverConnect(dbc, null, SQL_CONNECTION_STRING, SQL_NTS,
                    null, 0, null, SQL_DRIVER_NOPROMPT);
    if !SQL_SUCCEEDED(ret) {
        extract_error(dbc, SQL_HANDLE_DBC);
        return;
    }
    /* Allocate a statement handle */
    SQLAllocHandle(SQL_HANDLE_STMT, dbc, *stmt);
    /* Retrieve a list of tables */
    SQLTables(stmt, null, 0, null, 0, null, 0, "TABLE", SQL_NTS);
    /* How many columns are there */
    SQLNumResultCols(stmt, *columns);
    /* Loop through the rows in the result-set */
    while SQL_SUCCEEDED(ret) {
        ret = SQLFetch(stmt);
        print("Row %\n", row);
        row += 1;
        /* Loop through the columns */
        i : SQLUSMALLINT = 1;
        for i..cast(u16)columns {
            indicator: SQLLEN;
            buf: [512] u8;
            /* retrieve column data as a string */
            ret = SQLGetData(stmt, it, SQL_C_CHAR,
                            buf.data, buf.count, *indicator);
            if (SQL_SUCCEEDED(ret)) {
                /* Handle null columns */
                if (indicator == SQL_NULL_DATA) memcpy(buf.data, "NULL".data, 5);
                print("  Column % : %\n", it, to_string(buf.data));
            }
        }
    }
}

querry_datasources:: () {
    print("####### DATA SOURCES ######\n");
    env: SQLHENV;
    dsn: [256] u8;
    desc: [256] u8;
    dsn_ret: SQLSMALLINT;
    desc_ret: SQLSMALLINT;
    direction: SQLUSMALLINT;
    ret: SQLRETURN;

    SQLAllocHandle(SQL_HANDLE_ENV, xx SQL_NULL_HANDLE, *env);
    SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, cast(*void) SQL_OV_ODBC3, 0);

    direction = SQL_FETCH_FIRST;
    while SQL_SUCCEEDED(ret) {
        ret = SQLDataSources(env, direction, dsn.data, dsn.count, *dsn_ret, desc.data, desc.count, *desc_ret);
        direction = SQL_FETCH_NEXT;
        print("% - %\n", to_string(dsn), to_string(desc));
        if (ret == SQL_SUCCESS_WITH_INFO) then print("\tdata truncation\n");
    }
}

query_driver:: () {
    print("####### DRIVERS ######\n");
    env:SQLHENV;
    driver: [256] u8;
    attr: [256] u8;
    driver_ret: SQLSMALLINT;
    attr_ret: SQLSMALLINT;
    direction: SQLUSMALLINT;
    ret: SQLRETURN;

    SQLAllocHandle(SQL_HANDLE_ENV, null, *env);
    SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, cast(*void) SQL_OV_ODBC3, 0);

    direction = SQL_FETCH_FIRST;
    while SQL_SUCCEEDED(ret) {
        ret = SQLDrivers(env, direction, driver.data, driver.count, *driver_ret, attr.data, attr.count, *attr_ret);
        direction = SQL_FETCH_NEXT;
        print("% - %\n", to_string(driver), to_string(attr));
        if (ret == SQL_SUCCESS_WITH_INFO) then print("\tdata truncation\n");
    }
}

extract_error:: (handle: SQLHANDLE, type: SQLSMALLINT) {
    i: SQLSMALLINT;
    native: SQLINTEGER;
    state: [7] u8;
    text: [256] u8;
    len: SQLSMALLINT;
    ret: SQLRETURN;

    print("####### ERRORS ######\n");
    print("\n\nThe driver reported the following diagnostics whilst running\n\n");

    while SQL_SUCCEEDED(ret)
    {
        i += 1;
        ret = SQLGetDiagRec(type, handle, i, state.data, *native, text.data, text.count, *len);
        if (SQL_SUCCEEDED(ret))
            print("%:%:%:%\n", to_string(state), i, native, to_string(text));
    }
}