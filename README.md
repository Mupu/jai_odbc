<!-- https://github.com/fefong/markdown_readme/blob/master/README.md#Markdown-Editor -->
# Table of Contents
1. [What is Jai ODBC](#what-is-jai_odbc)
2. [Installation](#installation)
3. [Features](#features)
    1. [Supported Conversions](#supported-conversions)
    2. [Missing Features](#missing-features)
4. [Known Problems](#known-problems)
5. [Important Information](#important-information)
6. [API](#api)
7. [Examples](#examples)
8. [Contribution](#contribution)
    1. [Guidelines](#guidelines)
    2. [Markers](#markers)
    3. [Code Style and Conventions](#code-style-and-conventions)
9. [Tooling](#tooling)
    1. [Custom Git Hooks](#custom-git-hooks)
10. [ToDo](#todo)
11. [License](#license)

# What is jai_odbc?
Jai ODBC is a simple wrapper for ODBC, which exposes a simple API to make SQL requests and parse it's data into structs. Currently it has only been used and tested on Windows with MSSQL 2022 with the `SQL Server Native Client 11.0`, `ODBC Driver 17 for SQL Server`, and `ODBC Driver 18 for SQL Server` drivers. If you have any feedback, or improvements feel free to ping me on the Discord. If you want to contribute take a look in the [Contribution](#contribution) section.

# Installation
You need at least Jai `version beta 0.1.049` or higher. Download the repository and import it with `#import "jai_odbc"`. Also make sure to read [Important Information](#important-information) and to look at the [examples](#examples).

# Features
Jai ODBC lets you define a struct to which the results will be mapped. Currently the mapping is a 1 to 1 mapping between the StructMemberName and the returned columnnames. After that you just call the API, pass it the type, the query, and the arguments. NOTE: Youre supposed to pass the arguments by making use of parameterized queries. It will also prevent you from accidentilly creating SQL injection. 
<br>The API is super convienent to use and saves you from having to write any table-to-structure-binding boilerplate code, like you have to in C/Cpp. Currently, the [API](#api) is super small and minimalistic. But it may be expanded in the future. 
<br>A list of supported types and conversions can be found below. Examples can found [here](#examples).

## Supported Conversions
- :heavy_check_mark: means bidirectional
- :arrow_up: means from the left(Jai) convertable to the top(SQL)
- :a:arrow_left:: means from the top(SQL) convertable to the left(Jai) 
- :x: means not supported

|x             |SQLString         |SQLInteger        |Real & SQLFloat   |SQLBinary         |Date/Time         |
|-------------:|:----------------:|:----------------:|:----------------:|:----------------:|:----------------:|
|String        |:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|:x:               |:heavy_check_mark:|
|Integer       |:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|:arrow_up:        |:x:               |
|Float/Double  |:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|:arrow_up:        |:x:               |
|All u8 Arrays |:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|:x:               |
|Apollo_Time   |:x:               |:x:               |:x:               |:x:               |:heavy_check_mark:|
* `Integer` includes the types `s8`, `u8`, `s16`, `u16`, `s32`, `u32`, `s64`, `u64`.<br> NOTE: See [Known Problems](#known-problems)
* `SQLString` includes the types `char`, `varchar(max)`, `nchar`, `nvarchar(max)`
* `SQLBinary` includes the types `binary`, `varbinary`
* `SQLInteger` includes the types `TINYINT`, `SMALLINT`, `INT`, `BIGINT`
* `SQLFloat` only the default one without the bit specifier was tested.

## Missing Features
* ENUM support without casting
* Do we want pointers to be a thing? Seems not worth.
* Transaction management
* Expand API e.g. INSERT/UPDATE with Structs or AoS directly etc.
* Multithreading?
* Reconnecting?
* Column name alias? It can already be achieved with `AS` statement in sql ..
* Maybe more type conversions
* Linux support?

# Known Problems
* Dont use the `SQL Server` Driver as it seems to break some functionality.
* Not sure, if full unsigned range works. Although the documentation mentions unsigned integer ranges, MSSQL doesn't seem to support them?. If anyone knows more about this, please contact me. They probably don't work with the full range. Be warned. :IntegerTests
* I havent tested `char` and `varchar` with UTF-8 enabled. Dont expect it to work. But maybe it does.
* Inputting long strings and binary doesnt work right now :LongStringInput

# Important Information
* It is not adviced to push any allocator, that does not support free and resize. It is especially important when querying long (> 8000 bytes) `nvarchar(max)` strings. The reason beeing, that we have to convert from UTF-16 to UTF-8. 

# API
* `connect:: (conn_str: string, location:= #caller_location) ->  (state: DB_Connection #must, success: bool)`<br>
Tries to connect to a database.
<br>Returns a DB_Connection object which you need to call `disconnect` on, when not needed anymore. **Even** when `false` was returned.

* `disconnect:: (state: *DB_Connection, location:= #caller_location)`<br>
Disconnects from the DB and frees the handles.

* `release:: (data_to_free: *Data_To_Free)`<br>
Releases all data given to it, that the query allocated.

* `execute:: (using connection: *DB_Connection, $T: Type, command: string, args: .. Any, $ignore_unknown:= Unkown_Result_Mode.CRASH, location:= #caller_location) -> (success: bool, data_to_free: Data_To_Free #must, results: [] T, has_value: [] bool, modified_rows: int)`<br> 
Execute a sql command and parse the result into a given struct. Please use parameterized queries with '?' as a placeholder, insead of using string modifications on the command string, to avoid sql injections. 
<br>`results`, `has_value`, and `modified_rows` are undefined if `success` returned `false` 
<br>returns `true` if everything worked. `false` otherwise. Errors will be logged. 
<br><br>**NOTE**: This procedure an struct with contains all data that needs to be freed by calling `released(*data_to_free)`. Even if this procedure returns false.

* `execute:: inline (using connection: *DB_Connection, command: string, args: .. Any, location:= #caller_location) -> (success: bool, modified_rows: int)`<br>
This function should be used for statements that don't return data like UPDATE, DELETE etc. Everything else is the same with the exception, that nothing has to be freed after this call. It's done for you and the return values. For more information see notes for `execute`.

* `EXECUTE:: (using connection: *DB_Connection, $T: Type, command: string, args: .. Any, $ignore_unknown:= Unkown_Result_Mode.CRASH, location:= #caller_location) -> (success: bool, results: [] T, has_value: [] bool) #expand {`<br>
Wrapper for `execute` with the difference that it automatically frees the results data on end of scope(defer) and has different return values. For more information see notes for `execute`.

 More Tests and a better way to write them

# Examples
For more examples, especially for the usage of different types, you can look at `db_test` in [Tests](https://github.com/Mupu/jai_odbc/blob/main/test.jai).
```c
// Try to connect to the database.
state, connection_success:= connect("Driver={ODBC Driver 18 for SQL Server};Server=MUPU;Database=Test;Trusted_Connection=Yes;");
assert(connection_success);
defer disconnect(*state); // Disconnect later on, EVEN on failure! Although, the assert saves us in this case anyways.

{
    // Create struct which the result will map to.
    Dummy:: struct {
        testVal: string; // Has to match the sql column's name.
    }

    // Until there is column aliasing, you can rename the columns in the query to match the struct.
    // NOTE: for Data Query statements modified_rows should always be 0. So here, you could ignore it.
    success, data_to_free, results, has_value, modified_rows:= execute(*state, Dummy, "SELECT testString as testVal FROM Test");
    defer release(*data_to_free); // Free when done.
    assert(success);


    // Automatic free
    success, results, has_value:= EXECUTE(*state, JaiTest, "SELECT testBinary, testDouble FROM [Test]");
    assert(success);

    // Use this when u dont have any results.
    success, modified_rows:= execute(*state, "UPDATE [Test] SET testString = ", "test");

    // If your columns can be 'null', you can check for that by using 'has_value'
    //
    // NOTE: As of now this sucks. THE ORDER OF THE COLUMN IS THE SAME AS IN YOUR SQL QUERY! 
    // You retrieve the correct value by calculating the index like this:
    // 
    index_of_column:= row_0_index * results.count + column_0_index;
    if has_value[index_of_column] then return false;
}

{
    my_int:= 5;
    // Use this one without a Type, for queries that dont return data.
    success, rows:= execute(*state, "UPDATE Test SET testInt = ?", my_int); // Rows will tell you how many rows were modified.
    assert(success);
}

{
    Dummy:: struct {
        testVal: string;
    }
    // Frees automatically on scope end(defer)
    success, results, has_value:= EXECUTE(*state, Dummy, "SELECT testString as testVal FROM Test WHERE testInt = ?", 8);
    assert(success);
}

```

# Contribution
## Guidelines
If you wanna contribute, feel free to make a pull request or open issues. If you do so, please name your commits as specified in [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) and/or use the githooks(See: [Tooling](#custom-git-hooks)) to enforce it.

## Markers
If you wanna mark specific things to find later or that belong together, but are in different places, you can mark them by doing `:MyCoolTag`. Also you can use the following common annotations:
* `@todo`        - Selfexplanitory.
* `@incomplete`  - When something is not complete.
* `@cleanup`     - When something can be cleaned up or be refactored.
* `@fix`         - Selfexplanitory.
* `@optimize`    - To clearify that this can or should be optimized. This could be speed or memory footprint for example.
* `@leak`        - If you leak something on purpose. 
* `@hack`        - If you know its not a proper way to do something, but maybe theres no other way right now.
* `@temporary`   - Code that will need to be removed in the future. e.g. something that cant get removed right now because of a dependency.
* `@investigate` - Code that will need to be checked for something, but is not necessarily wrong.
* `NOTE:`        - If you want to mention something more important in a text.
* `WARNING:`     - If you want to warn about something important, that e.g. you need to know to use something.

## Code Style and Conventions
For this project I have decided to try a new style. Also we will use snake case. Please try to follow this example when commiting code.
```c

//
// General definitions:
// - count is 1 based and used for counting. e.g. array elements
// - index is 0 based and used for e.g. for iterating
// - size  is in bytes and used for e.g. keeping track of memory sizes
//
// Example:
//
// data: [10] u16;
// count = 10 elements
// size  = 20 bytes
// 
// index = it => for data {}


#import "Basic"; // imports and loads on top
#load "file.jai"; // imports and loads on top
DEBUG:: #import "Debug"; // no space, constants in capital latters

// Types have capital first latters
Unkown_Result_Mode:: enum {
    CRASH; // enum and enum_flags are capitalized
    WARN;
    SILENT;
}

// Types have capital first latters
Dummy_Thing:: struct { // brackets same line, no space between 'test1' and '::'
    decleration: int; // ':' go to identifier
    decleration_with_default: int = 5;
    CONSTANT:: 8;
    CONSTANT_WITH_TYPE: int : 8;

    // aligned values
    value0:     = 5;
    value1: int = 5;
    longer:     = 8;
    HELLO:      : 8; 
    PETER:  int : 8;
}

// identifiers use snake case
// name your return values if they are not SUPER obvious
test_long:: (text: string) -> name_return_values: bool {
{
}

test_modify:: (text: string) -> (name_return_values: bool) #modify { // put braket around return when using #modify
	return false;
}
{

}

// put brackets if multiple return values are there
// and only use #must for things that cannot be fixed when forgetting,
// like leaking memory like below
test2:: (text: string) -> (multiple: bool, return_values: *int #must) {

    b_exists:= text.count > 0; // DONT prefix with types or whatever

    prefixed_text:= tprint("HAHA: %\n", text); // always name variables smth usefull. And do not abbriviate.
    for value: 1..8 { // you can use 'it' though. just name it if its a bigger function so you dont have to scroll
        if value == {
            case 1; return....
            case; ....
        }
    }

    my_int:= New(int);
    
    my_int2, test:= function_with_multiple_returns(); // no space 

    return true, my_int;

}

MY_MACRO:: () #expand { // name macros in capital letters!

}

operator ==:: (a: int, b: int) {} // no space
blub:: (a:= 5, loc:= #caller_location) {} // no space

```


# Tooling
No tooling needed other than the Jai compiler :)<br> But it is recommended to use the githooks.
## Custom Git Hooks
To install them simply run `GIT_HOOKS_UNINSTALL.bat` after cloning.
To uninstall them run `GIT_HOOKS_UNINSTALL.bat`. NOTE: At least for me the hooks completely break after I modified/opened the script. If thats the case for you aswell, just redownload them.
<br><br>Currently distributed hooks are..
  - .. `nocheckin` - prevents commits that include the keyword **nocheckin**. So, whenever you want to 
      not forget, that you added/changed something temporarily, just add **nocheckin** anywhere. 
  - .. `conventional-commit-message` - prevents commits that don't follow the 
      [Conventional Commits](https://www.conventionalcommits.org/) formatting.

# TODO
This list is more or less for me, but also for contributors. Generally, the top is a higher priority, but not strictly.
* @fix :LongStringInput
* :utf8Conversion
* @incomplete POOL_ALLOCATOR_CUTOFF_SIZE. Give user option to change the buffer sizes? :UserOptions
* @incomplete :SQL_NO_TOTAL
* @investigate: does execute break when this function is called with context.allocator = temp?
* parameter counting / checking
* Improve NULL checking
* More tests. For all integer types and long binary/strings. And conversions. :IntegerTests :LongStringInput

# License
This project is licensed under the BSD 3-Clause License. See [LICENSE.md](https://github.com/Mupu/jai_odbc/blob/main/LICENSE.md).