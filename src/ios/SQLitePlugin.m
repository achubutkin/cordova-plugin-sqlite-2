/*
 * Author: Nolan Lawson
 * License: Apache 2
 */

#import "SQLitePlugin.h"
#import "sqlite3.h"

// Uncomment this to enable debug mode
#define DEBUG_MODE = 1;

#ifdef DEBUG_MODE
#   define logDebug(...) NSLog(__VA_ARGS__)
#else
#   define logDebug(...)
#endif

@interface SQLitePluginResult : NSObject {
}

@property(nonatomic, copy) NSArray* rows;
@property(nonatomic, copy) NSArray* columns;
@property(nonatomic, copy) NSNumber* rowsAffected;
@property(nonatomic, copy) NSNumber* insertId;
@property(nonatomic, copy) NSString* error;

@end

@implementation SQLitePluginResult

@synthesize rows;
@synthesize columns;
@synthesize rowsAffected;
@synthesize insertId;
@synthesize error;

-(void)dealloc {
    [self setRows:nil];
    [self setColumns:nil];
    [self setRowsAffected:nil];
    [self setInsertId:nil];
    [self setError:nil];
}

@end

@implementation SQLitePlugin

@synthesize cachedDatabases;

-(void)pluginInitialize {
    logDebug(@"pluginInitialize()");
    cachedDatabases = [NSMutableDictionary dictionaryWithCapacity:0];
    NSString *dbDir = [self getDatabaseDir];
    [[NSFileManager defaultManager] createDirectoryAtPath: dbDir
                              withIntermediateDirectories:NO attributes: nil error:nil];
}

-(NSString*) getDatabaseDir {
    NSString *libDir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
    return [libDir stringByAppendingPathComponent:@"LocalDatabase"];
}

-(id) getPathForDB:(NSString *)dbName {
    
    // special case for in-memory databases
    if ([dbName isEqualToString:@":memory:"]) {
        return dbName;
    }
    // otherwise use this location, which matches the old SQLite Plugin behavior
    // and ensures no iCloud backup, which is apparently disallowed for SQLite dbs
    return [[self getDatabaseDir] stringByAppendingPathComponent: dbName];
}

-(NSValue*)openDatabase: (NSString*)dbName {
    logDebug(@"opening DB: %@", dbName);
    NSValue *cachedDB = [cachedDatabases objectForKey:dbName];
    if (cachedDB == nil) {
        logDebug(@"opening new db");
        NSString *fullDbPath = [self getPathForDB: dbName];
        logDebug(@"full path: %@", fullDbPath);
        const char *sqliteName = [fullDbPath UTF8String];
        sqlite3 *db;
        if (sqlite3_open(sqliteName, &db) != SQLITE_OK) {
            logDebug(@"cannot open database: %@", dbName); // shouldn't happen
        };
        cachedDB = [NSValue valueWithPointer:db];
        [cachedDatabases setObject: cachedDB forKey: dbName];
    } else {
        logDebug(@"re-using existing db");
    }
    return cachedDB;
}

-(void) exec: (CDVInvokedUrlCommand*)command
{
    logDebug(@"exec()");
    [self.commandDelegate runInBackground:^{
        [self execOnBackgroundThread: command];
    }];
}

-(void) execOnBackgroundThread: (CDVInvokedUrlCommand *)command
{
    logDebug(@"execOnBackgroundThread()");
    NSString *dbName = [command.arguments objectAtIndex:0];
    NSArray *sqlQueries = [command.arguments objectAtIndex:1];
    BOOL readOnly = [command.arguments objectAtIndex:2];
    long length = [sqlQueries count];
    SQLitePluginResult *sqlResult;
    int i;
    logDebug(@"dbName: %@", dbName);
    @synchronized(self) {
        NSValue *databasePointer = [self openDatabase:dbName];
        sqlite3 *db = [databasePointer pointerValue];
        NSMutableArray *sqlResults = [NSMutableArray arrayWithCapacity:0];
        
        // execute queries
        for (i = 0; i < length; i++) {
            NSArray *sqlQueryObject = [sqlQueries objectAtIndex:i];
            NSString *sql = [sqlQueryObject objectAtIndex:0];
            NSArray *sqlArgs = [sqlQueryObject objectAtIndex:1];
            logDebug(@"sql: %@", sql);
            logDebug(@"sqlArgs: %@", sqlArgs);
            sqlResult = [self executeSql:sql withSqlArgs:sqlArgs withDb: db withReadOnly: readOnly];
            [sqlResults addObject:sqlResult];
        }
        
        // transform results back into plain arrays
        NSMutableArray *finalResult = [NSMutableArray arrayWithCapacity:0];
        for (i = 0; i < length; i++) {
            sqlResult = [sqlResults objectAtIndex:i];
            
            NSString *error = sqlResult.error;
            if (error != nil) {
                NSArray *result = @[error, [NSNull null], [NSNull null], [NSNull null], [NSNull null]];
                [finalResult addObject:result];
            } else {
                NSArray *columns = sqlResult.columns;
                NSArray *rows = sqlResult.rows;
                NSNumber *rowsAffected = sqlResult.rowsAffected;
                NSNumber *insertId = sqlResult.insertId;
                NSArray *result = @[[NSNull null], insertId, rowsAffected, columns, rows];
                [finalResult addObject:result];
            }
        }
        
        // send the result back to Cordova
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:finalResult];
        [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
    }
    
}

-(NSObject*) getSqlValueForColumnType: (int)columnType withStatement: (sqlite3_stmt*)statement withIndex: (int)i {
    switch (columnType) {
        case SQLITE_INTEGER:
            return [NSNumber numberWithLongLong: sqlite3_column_int64(statement, i)];
        case SQLITE_FLOAT:
            return [NSNumber numberWithDouble: sqlite3_column_double(statement, i)];
        case SQLITE_BLOB:
        case SQLITE_TEXT:
            return [[NSString alloc] initWithBytes:(char *)sqlite3_column_text(statement, i)
                                            length:sqlite3_column_bytes(statement, i)
                                          encoding:NSUTF8StringEncoding];
    }
    return [NSNull null];
}

-(SQLitePluginResult*) executeSql: (NSString*)sql
                       withSqlArgs: (NSArray*)sqlArgs
                       withDb: (sqlite3*)db
                       withReadOnly: (BOOL)readOnly {
    logDebug(@"executeSql sql: %@", sql);
    NSString *error = nil;
    sqlite3_stmt *statement;
    int i;
    int newRowsAffected;
    int diffRowsAffected;
    long long currentInsertId;
    SQLitePluginResult *resultSet = [SQLitePluginResult alloc];
    NSMutableArray *resultRows = [NSMutableArray arrayWithCapacity:0];
    NSMutableArray *entry;
    
    NSNumber *insertId;
    NSNumber *rowsAffected;
    
    // compile the statement, throw an error if necessary
    logDebug(@"sqlite3_prepare_v2");
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
        error = [SQLitePlugin convertSQLiteErrorToString:db];
        logDebug(@"prepare error!");
        logDebug(@"error: %@", error);
        [resultSet setError:error];
        return resultSet;
    }
    
    // bind any arguments
    if (sqlArgs != NULL) {
        for (i = 0; i < sqlArgs.count; i++) {
            [self bindStatement:statement withArg:[sqlArgs objectAtIndex:i] atIndex:(i + 1)];
        }
    }
    
    // calculate the total changes in order to diff later
    int previousRowsAffected = sqlite3_total_changes(db);
    
    // iterate through sql results
    int columnCount;
    NSMutableArray *columnNames = [NSMutableArray arrayWithCapacity:0];
    NSMutableArray *columnTypes = [NSMutableArray arrayWithCapacity:0];
    NSString *columnName;
    int columnType;
    BOOL fetchedColumns = NO;
    BOOL hasInsertId = NO;
    BOOL hasMore = YES;
    int result;
    NSObject *columnValue;
    while (hasMore) {
        logDebug(@"sqlite3_step");
        result = sqlite3_step (statement);
        switch (result) {
            case SQLITE_ROW:
                if (!fetchedColumns) {
                    // get all column names and column types once as the beginning
                    columnCount = sqlite3_column_count(statement);
                    for (i = 0; i < columnCount; i++) {
                        columnName = [NSString stringWithFormat:@"%s", sqlite3_column_name(statement, i)];
                        columnType = sqlite3_column_type(statement, i);
                        [columnNames addObject:columnName];
                        [columnTypes addObject:[NSNumber numberWithInteger:columnType]];
                    }
                    fetchedColumns = YES;
                }
                entry = [NSMutableArray arrayWithCapacity:0];
                for (i = 0; i < columnCount; i++) {
                    columnType = [[columnTypes objectAtIndex:i] intValue];
                    columnValue = [self getSqlValueForColumnType:columnType withStatement:statement withIndex: i];
                    [entry addObject:columnValue];
                }
                [resultRows addObject:entry];
                break;
            case SQLITE_DONE:
                newRowsAffected = sqlite3_total_changes(db);
                diffRowsAffected = newRowsAffected - previousRowsAffected;
                rowsAffected = [NSNumber numberWithInt:(newRowsAffected - previousRowsAffected)];
                currentInsertId = sqlite3_last_insert_rowid(db);
                if (newRowsAffected > 0 && currentInsertId != 0) {
                    hasInsertId = YES;
                    insertId = [NSNumber numberWithLongLong:sqlite3_last_insert_rowid(db)];
                }
                hasMore = NO;
                break;
                
            default:
                error = [SQLitePlugin convertSQLiteErrorToString:db];
                hasMore = NO;
        }
    }
    
    logDebug(@"sqlite3_finalize");
    sqlite3_finalize (statement);
    
    if (error) {
        [resultSet setError:error];
    } else {
        [resultSet setRows:resultRows];
        [resultSet setColumns:columnNames];
        [resultSet setRowsAffected:rowsAffected];
        if (hasInsertId) {
            [resultSet setInsertId:insertId];
        } else {
            [resultSet setInsertId:[NSNumber numberWithInt:0]];
        }
    }
    
    logDebug(@"done executeSql sql: %@", sql);
    return resultSet;
}

-(void)bindStatement:(sqlite3_stmt *)statement withArg:(NSObject *)arg atIndex:(int)argIndex
{
    if ([arg isEqual:[NSNull null]]) {
        sqlite3_bind_null(statement, argIndex);
    } else if ([arg isKindOfClass:[NSNumber class]]) {
        NSNumber *numberArg = (NSNumber *)arg;
        const char *numberType = [numberArg objCType];
        if (strcmp(numberType, @encode(int)) == 0 ||
            strcmp(numberType, @encode(long long int)) == 0) {
            sqlite3_bind_int64(statement, argIndex, [numberArg longLongValue]);
        } else if (strcmp(numberType, @encode(double)) == 0) {
            sqlite3_bind_double(statement, argIndex, [numberArg doubleValue]);
        } else {
            sqlite3_bind_text(statement, argIndex, [[arg description] UTF8String], -1, SQLITE_TRANSIENT);
        }
    } else { // NSString
        NSString *stringArg;
        
        if ([arg isKindOfClass:[NSString class]]) {
            stringArg = (NSString *)arg;
        } else {
            stringArg = [arg description]; // convert to text
        }
        
        NSData *data = [stringArg dataUsingEncoding:NSUTF8StringEncoding];
        sqlite3_bind_text(statement, argIndex, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    }
}

-(void)dealloc {
    int i;
    NSArray *keys = [cachedDatabases allKeys];
    NSValue *pointer;
    NSString *key;
    sqlite3 *db;
    for (i = 0; i < [keys count]; i++) {
        key = [keys objectAtIndex:i];
        pointer = [cachedDatabases objectForKey:key];
        db = [pointer pointerValue];
        sqlite3_close (db);
    }
}

+(NSString *)convertSQLiteErrorToString:(struct sqlite3 *)db
{
    int code = sqlite3_errcode(db);
    const char *cMessage = sqlite3_errmsg(db);
    NSString *message = [[NSString alloc] initWithUTF8String: cMessage];
    return [NSString stringWithFormat:@"Error code %i: %@", code, message];
}

@end