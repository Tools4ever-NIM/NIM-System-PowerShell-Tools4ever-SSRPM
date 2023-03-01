# SSRPM.ps1 - SSRPM Onboarding

# Put a comma-separated list of attribute names here, whose value should be masked before 
# writing to log files. Examples are: 'Password','accountPassword'
$Log_MaskableKeys = @()


#
# System functions
#

function Idm-SystemInfo {
    param (
        # Operations
        [switch] $Connection,
        [switch] $TestConnection,
        [switch] $Configuration,
        # Parameters
        [string] $ConnectionParams
    )
    Log info "-Connection=$Connection -TestConnection=$TestConnection -Configuration=$Configuration -ConnectionParams='$ConnectionParams'"
    
    if ($Connection) {
        @(
            @{
                name = 'server'
                type = 'textbox'
                label = 'Server'
                description = 'Name of Microsoft SQL server'
                value = ''
            }
            @{
                name = 'database'
                type = 'textbox'
                label = 'Database'
                description = 'Name of Microsoft SQL database'
                value = 'SSRPM'
            }
            @{
                name = 'use_svc_account_creds'
                type = 'checkbox'
                label = 'Use credentials of service account'
                value = $true
            }
            @{
                name = 'username'
                type = 'textbox'
                label = 'Username'
                label_indent = $true
                description = 'User account name to access Microsoft SQL server'
                value = ''
                hidden = 'use_svc_account_creds'
            }
            @{
                name = 'password'
                type = 'textbox'
                password = $true
                label = 'Password'
                label_indent = $true
                description = 'User account password to access Microsoft SQL server'
                value = ''
                hidden = 'use_svc_account_creds'
            }
            @{
                name = 'url'
                type = 'textbox'
                password = $false                # Password control
                label = 'SSRPM Web Service URL'
                value = 'https://ssrpm.domain.com'
            }
            @{
                name = 'token'
                type = 'textbox'
                password = $true                # Password control
                label = 'API Token'
                value = ''
            }
            @{
                name = 'nr_of_sessions'
                type = 'textbox'
                label = 'Max. number of simultaneous sessions'
                description = ''
                value = 5
            }
            @{
                name = 'sessions_idle_timeout'
                type = 'textbox'
                label = 'Session cleanup idle time (minutes)'
                description = ''
                value = 30
            }
        )
    }

    if ($TestConnection) {
        Open-MsSqlConnection $ConnectionParams
    }

    if ($Configuration) {
        @()
    }

    Log info "Done"
}


function Idm-OnUnload {
    Close-MsSqlConnection
}

#
# CRUD functions
#

$ColumnsInfoCache = @{}


function Fill-SqlInfoCache {
    param (
        [switch] $Force
    )

    if (!$Force -and $Global:SqlInfoCache.Ts -and ((Get-Date) - $Global:SqlInfoCache.Ts).TotalMilliseconds -le [Int32]600000) {
        return
    }

    # Refresh cache
    $sql_command = New-MsSqlCommand "
        SELECT
            ss.name + '.[' + st.name + ']' AS full_object_name,
            (CASE WHEN st.type = 'U' THEN 'Table' WHEN st.type = 'V' THEN 'View' ELSE 'Other' END) AS object_type,
            sc.name AS column_name,
            CAST(CASE WHEN pk.COLUMN_NAME IS NULL THEN 0 ELSE 1 END AS BIT) AS is_primary_key,
            sc.is_identity,
            sc.is_computed,
            sc.is_nullable
        FROM
            sys.schemas AS ss
            INNER JOIN (
                SELECT
                    name, object_id, schema_id, type
                FROM
                    sys.tables
                UNION ALL
                SELECT
                    name, object_id, schema_id, type
                FROM
                    sys.views
            ) AS st ON ss.schema_id = st.schema_id
            INNER JOIN sys.columns AS sc ON st.object_id = sc.object_id
            LEFT JOIN (
                SELECT
                    CCU.*
                FROM
                    INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE AS CCU
                    INNER JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS TC ON CCU.CONSTRAINT_NAME = TC.CONSTRAINT_NAME
                WHERE
                    TC.CONSTRAINT_TYPE = 'PRIMARY KEY'
            ) AS pk ON ss.name = pk.TABLE_SCHEMA AND st.name = pk.TABLE_NAME AND sc.name = pk.COLUMN_NAME
        ORDER BY
            full_object_name, sc.column_id
    "

    $objects = New-Object System.Collections.ArrayList
    $object = @{}

    # Process in one pass
    Invoke-MsSqlCommand $sql_command | ForEach-Object {
        if ($_.full_object_name -ne $object.full_name) {
            if ($object.full_name -ne $null) {
                $objects.Add($object) | Out-Null
            }

            $object = @{
                full_name = $_.full_object_name
                type      = $_.object_type
                columns   = New-Object System.Collections.ArrayList
            }
        }

        $object.columns.Add(@{
            name           = $_.column_name
            is_primary_key = $_.is_primary_key
            is_identity    = $_.is_identity
            is_computed    = $_.is_computed
            is_nullable    = $_.is_nullable
        }) | Out-Null
    }

    if ($object.full_name -ne $null) {
        $objects.Add($object) | Out-Null
    }

    Dispose-MsSqlCommand $sql_command

    $Global:SqlInfoCache.Objects = $objects
    $Global:SqlInfoCache.Ts = Get-Date
}

function Idm-Dispatcher {
    param (
        # Optional Class/Operation
        [string] $Class,
        [string] $Operation,
        # Mode
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-Class='$Class' -Operation='$Operation' -GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($Class -eq '') {

        if ($GetMeta) {
            #
            # Get all tables and views in database
            #

            Open-MsSqlConnection $SystemParams

            Fill-SqlInfoCache -Force

            #
            # Output list of supported operations per table/view (named Class)
            #

            @(
                foreach ($object in $Global:SqlInfoCache.Objects) {
                    $primary_keys = $object.columns | Where-Object { $_.is_primary_key } | ForEach-Object { $_.name }

                    if ($object.type -ne 'Table') {
                        # Non-tables only support 'Read'
                        [ordered]@{
                            Class = $object.full_name
                            Operation = 'Read'
                            'Source type' = $object.type
                            'Primary key' = $primary_keys -join ', '
                            'Supported operations' = 'R'
                        }
                    }
                    else {
                        [ordered]@{
                            Class = $object.full_name
                            Operation = 'Create'
                        }

                        [ordered]@{
                            Class = $object.full_name
                            Operation = 'Read'
                            'Source type' = $object.type
                            'Primary key' = $primary_keys -join ', '
                            'Supported operations' = "CR$(if ($primary_keys) { 'UD' } else { '' })"
                        }

                        if ($primary_keys) {
                            # Only supported if primary keys are present
                            [ordered]@{
                                Class = $object.full_name
                                Operation = 'Update'
                            }

                            [ordered]@{
                                Class = $object.full_name
                                Operation = 'Delete'
                            }
                        }
                    }
                }
            )

        }
        else {
            # Purposely no-operation.
        }

    }
    else {

        if ($GetMeta) {
            #
            # Get meta data
            #

            Open-MsSqlConnection $SystemParams

            Fill-SqlInfoCache

            $columns = ($Global:SqlInfoCache.Objects | Where-Object { $_.full_name -eq $Class }).columns

            switch ($Operation) {
                'Create' {
                    @{
                        semantics = 'create'
                        parameters = @(
                            $columns | ForEach-Object {
                                @{
                                    name = $_.name;
                                    allowance = if ($_.is_identity -or $_.is_computed) { 'prohibited' } elseif (! $_.is_nullable) { 'mandatory' } else { 'optional' }
                                }
                            }
                        )
                    }
                    break
                }

                'Read' {
                    @(
                        @{
                            name = 'where_clause'
                            type = 'textbox'
                            label = 'Filter (SQL where-clause)'
                            description = 'Applied SQL where-clause'
                            value = ''
                        }
                        @{
                            name = 'selected_columns'
                            type = 'grid'
                            label = 'Include columns'
                            description = 'Selected columns'
                            table = @{
                                rows = @($columns | ForEach-Object {
                                    @{
                                        name = $_.name
                                        config = @(
                                            if ($_.is_primary_key) { 'Primary key' }
                                            if ($_.is_identity)    { 'Generated' }
                                            if ($_.is_computed)    { 'Computed' }
                                            if ($_.is_nullable)    { 'Nullable' }
                                        ) -join ' | '
                                    }
                                })
                                settings_grid = @{
                                    selection = 'multiple'
                                    key_column = 'name'
                                    checkbox = $true
                                    filter = $true
                                    columns = @(
                                        @{
                                            name = 'name'
                                            display_name = 'Name'
                                        }
                                        @{
                                            name = 'config'
                                            display_name = 'Configuration'
                                        }
                                    )
                                }
                            }
                            value = @($columns | ForEach-Object { $_.name })
                        }
                    )
                    break
                }

                'Update' {
                    @{
                        semantics = 'update'
                        parameters = @(
                            $columns | ForEach-Object {
                                @{
                                    name = $_.name;
                                    allowance = if ($_.is_primary_key) { 'mandatory' } else { 'optional' }
                                }
                            }
                            @{
                                name = '*'
                                allowance = 'prohibited'
                            }
                        )
                    }
                    break
                }

                'Delete' {
                    @{
                        semantics = 'delete'
                        parameters = @(
                            $columns | ForEach-Object {
                                if ($_.is_primary_key) {
                                    @{
                                        name = $_.name
                                        allowance = 'mandatory'
                                    }
                                }
                            }
                            @{
                                name = '*'
                                allowance = 'prohibited'
                            }
                        )
                    }
                    break
                }
            }

        }
        else {
            #
            # Execute function
            #

            Open-MsSqlConnection $SystemParams

            if (! $Global:ColumnsInfoCache[$Class]) {
                Fill-SqlInfoCache

                $columns = ($Global:SqlInfoCache.Objects | Where-Object { $_.full_name -eq $Class }).columns

                $Global:ColumnsInfoCache[$Class] = @{
                    primary_keys = @($columns | Where-Object { $_.is_primary_key } | ForEach-Object { $_.name })
                    identity_col = @($columns | Where-Object { $_.is_identity    } | ForEach-Object { $_.name })[0]
                }
            }

            $primary_keys = $Global:ColumnsInfoCache[$Class].primary_keys
            $identity_col = $Global:ColumnsInfoCache[$Class].identity_col

            $function_params = ConvertFrom-Json2 $FunctionParams

            # Replace $null by [System.DBNull]::Value
            $keys_with_null_value = @()
            foreach ($key in $function_params.Keys) { if ($function_params[$key] -eq $null) { $keys_with_null_value += $key } }
            foreach ($key in $keys_with_null_value) { $function_params[$key] = [System.DBNull]::Value }

            $sql_command = New-MsSqlCommand

            $projection = if ($function_params['selected_columns'].count -eq 0) { '*' } else { @($function_params['selected_columns'] | ForEach-Object { "[$_]" }) -join ', ' }

            switch ($Operation) {
                'Create' {
                    $filter = if ($identity_col) {
                                  "[$identity_col] = SCOPE_IDENTITY()"
                              }
                              elseif ($primary_keys) {
                                  @($primary_keys | ForEach-Object { "[$_] = $(AddParam-MsSqlCommand $sql_command $function_params[$_])" }) -join ' AND '
                              }
                              else {
                                  @($function_params.Keys | ForEach-Object { "[$_] = $(AddParam-MsSqlCommand $sql_command $function_params[$_])" }) -join ' AND '
                              }

                    $sql_command.CommandText = "
                        INSERT INTO $Class (
                            $(@($function_params.Keys | ForEach-Object { "[$_]" }) -join ', ')
                        )
                        VALUES (
                            $(@($function_params.Keys | ForEach-Object { AddParam-MsSqlCommand $sql_command $function_params[$_] }) -join ', ')
                        );
                        SELECT TOP(1)
                            $projection
                        FROM
                            $Class
                        WHERE
                            $filter
                    "
                    break
                }

                'Read' {
                    $filter = if ($function_params['where_clause'].length -eq 0) { '' } else { " WHERE $($function_params['where_clause'])" }

                    $sql_command.CommandText = "
                        SELECT
                            $projection
                        FROM
                            $Class$filter
                    "
                    break
                }

                'Update' {
                    $filter = @($primary_keys | ForEach-Object { "[$_] = $(AddParam-MsSqlCommand $sql_command $function_params[$_])" }) -join ' AND '

                    $sql_command.CommandText = "
                        UPDATE TOP(1)
                            $Class
                        SET
                            $(@($function_params.Keys | ForEach-Object { if ($_ -notin $primary_keys) { "[$_] = $(AddParam-MsSqlCommand $sql_command $function_params[$_])" } }) -join ', ')
                        WHERE
                            $filter;
                        SELECT TOP(1)
                            $(@($function_params.Keys | ForEach-Object { "[$_]" }) -join ', ')
                        FROM
                            $Class
                        WHERE
                            $filter
                    "
                    break
                }

                'Delete' {
                    $filter = @($primary_keys | ForEach-Object { "[$_] = $(AddParam-MsSqlCommand $sql_command $function_params[$_])" }) -join ' AND '

                    $sql_command.CommandText = "
                        DELETE TOP(1)
                            $Class
                        WHERE
                            $filter
                    "
                    break
                }
            }

            if ($sql_command.CommandText) {
                $deparam_command = DeParam-MsSqlCommand $sql_command

                LogIO info ($deparam_command -split ' ')[0] -In -Command $deparam_command

                if ($Operation -eq 'Read') {
                    # Streamed output
                    Invoke-MsSqlCommand $sql_command $deparam_command
                }
                else {
                    # Log output
                    $rv = Invoke-MsSqlCommand $sql_command $deparam_command | ForEach-Object { $_ }
                    LogIO info ($deparam_command -split ' ')[0] -Out $rv

                    $rv
                }
            }

            Dispose-MsSqlCommand $sql_command

        }

    }

    Log info "Done"
}


#
# Object CRUD functions
#

function Idm-dbo_OnBoardingUsersCreate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'create'
            parameters = @(
                @{ name = 'Domain';       allowance = 'mandatory'   }
                @{ name = 'sAMAccountName';               allowance = 'mandatory' }
                @{ name = 'ClaimID';           allowance = 'mandatory' }
                @{ name = 'Validation_Name';                    allowance = 'mandatory'  }
                @{ name = 'Validation_Value';     allowance = 'mandatory' }
                @{ name = 'Validation_Option';      allowance = 'mandatory' }
            )
        }
    }
    else {
        #
        # Execute function
        #
        $connection_params = ConvertFrom-Json2 $SystemParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        $account = [PSCustomObject]@{
            Action = "new"
            OnboardingToken = $connection_params.token;
            users = [System.Collections.ArrayList]@(
                        [PSCustomObject]@{
                            Domain = $properties.domain
                            SAMAccountName = $properties.SAMAccountName;
                            OnboardingDate = Get-Date -Format "yyyy-MM-dd";
                            Attributes = [System.Collections.ArrayList]@(
                                [PSCustomObject]@{
                                    Name = "ID"
                                    Value = $properties.ClaimID
                                    Options = 1
                                },
                                [PSCustomObject]@{
                                    Name = $properties.Validation_Name
                                    Value = $properties.Validation_Value
                                    Options = $properties.Validation_Option
                                }
                            )
                            };
            )
        };
        $rv = $true;
        try {
            $uri = "$($connection_params.url)/onboarding/import"

            Log info "REST - POST - $($uri)"
            $response = Invoke-WebRequest -Uri $uri -Method POST -ContentType "application/json" -Body ($account | ConvertTo-Json -Depth 10) -UseBasicParsing
            
            if(($response | ConvertFrom-Json).Success)
            {
                $rv = $false
                LogIO info "dbo_OnBoardingUsersCreate" -Out "Sucessfully Onboarded User"
            }
            else
            {
                throw $response.Content
            }
                
        }
        catch {
            Log error $_
            LogIO error "dbo_OnBoardingUsersCreate" -Out $_
        }
    }
    Log info "Done"
}


#
# Helper functions
#
function New-MsSqlCommand {
    param (
        [string] $CommandText
    )

    New-Object System.Data.SqlClient.SqlCommand($CommandText, $Global:MsSqlConnection)
}


function Dispose-MsSqlCommand {
    param (
        [System.Data.SqlClient.SqlCommand] $SqlCommand
    )

    $SqlCommand.Dispose()
}
function AddParam-MsSqlCommand {
    param (
        [System.Data.SqlClient.SqlCommand] $SqlCommand,
        $Param
    )

    $param_name = "@param$($SqlCommand.Parameters.Count)_"
    $param_value = if ($Param -isnot [system.array]) { $Param } else { $Param | ConvertTo-Json -Compress -Depth 32 }

    $SqlCommand.Parameters.AddWithValue($param_name, $param_value) | Out-Null

    return $param_name
}


function DeParam-MsSqlCommand {
    param (
        [System.Data.SqlClient.SqlCommand] $SqlCommand
    )

    $deparam_command = $SqlCommand.CommandText

    foreach ($p in $SqlCommand.Parameters) {
        $value_txt = 
            if ($p.Value -eq [System.DBNull]::Value) {
                'NULL'
            }
            else {
                switch ($p.SqlDbType) {
                    { $_ -in @(
                        [System.Data.SqlDbType]::Char
                        [System.Data.SqlDbType]::Date
                        [System.Data.SqlDbType]::DateTime
                        [System.Data.SqlDbType]::DateTime2
                        [System.Data.SqlDbType]::DateTimeOffset
                        [System.Data.SqlDbType]::NChar
                        [System.Data.SqlDbType]::NText
                        [System.Data.SqlDbType]::NVarChar
                        [System.Data.SqlDbType]::Text
                        [System.Data.SqlDbType]::Time
                        [System.Data.SqlDbType]::VarChar
                        [System.Data.SqlDbType]::Xml
                    )} {
                        "'" + $p.Value.ToString().Replace("'", "''") + "'"
                        break
                    }
        
                    default {
                        $p.Value.ToString().Replace("'", "''")
                        break
                    }
                }
            }

        $deparam_command = $deparam_command.Replace($p.ParameterName, $value_txt)
    }

    # Make one single line
    @($deparam_command -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ' '
}

function Invoke-MsSqlCommand {
    param (
        [System.Data.SqlClient.SqlCommand] $SqlCommand,
        [string] $DeParamCommand
    )

    # Streaming
    function Invoke-MsSqlCommand-ExecuteReader {
        param (
            [System.Data.SqlClient.SqlCommand] $SqlCommand
        )

        $data_reader = $SqlCommand.ExecuteReader()
        $column_names = @($data_reader.GetSchemaTable().ColumnName)

        if ($column_names) {

            $hash_table = [ordered]@{}

            foreach ($column_name in $column_names) {
                $hash_table[$column_name] = ""
            }

            $obj = New-Object -TypeName PSObject -Property $hash_table

            # Read data
            while ($data_reader.Read()) {
                foreach ($column_name in $column_names) {
                    $obj.$column_name = if ($data_reader[$column_name] -is [System.DBNull]) { $null } else { $data_reader[$column_name] }
                }

                # Output data
                $obj
            }

        }

        $data_reader.Close()
    }

    # Streaming
    function Invoke-MsSqlCommand-ExecuteReader00 {
        param (
            [System.Data.SqlClient.SqlCommand] $SqlCommand
        )

        $data_reader = $SqlCommand.ExecuteReader()
        $column_names = @($data_reader.GetSchemaTable().ColumnName)

        if ($column_names) {

            # Initialize result
            $hash_table = [ordered]@{}

            for ($i = 0; $i -lt $column_names.Count; $i++) {
                $hash_table[$column_names[$i]] = ''
            }

            $result = New-Object -TypeName PSObject -Property $hash_table

            # Read data
            while ($data_reader.Read()) {
                foreach ($column_name in $column_names) {
                    $result.$column_name = $data_reader[$column_name]
                }

                # Output data
                $result
            }

        }

        $data_reader.Close()
    }

    # Streaming
    function Invoke-MsSqlCommand-ExecuteReader01 {
        param (
            [System.Data.SqlClient.SqlCommand] $SqlCommand
        )

        $data_reader = $SqlCommand.ExecuteReader()
        $field_count = $data_reader.FieldCount

        while ($data_reader.Read()) {
            $hash_table = [ordered]@{}
        
            for ($i = 0; $i -lt $field_count; $i++) {
                $hash_table[$data_reader.GetName($i)] = $data_reader.GetValue($i)
            }

            # Output data
            New-Object -TypeName PSObject -Property $hash_table
        }

        $data_reader.Close()
    }

    # Non-streaming (data stored in $data_table)
    function Invoke-MsSqlCommand-DataAdapter-DataTable {
        param (
            [System.Data.SqlClient.SqlCommand] $SqlCommand
        )

        $data_adapter = New-Object System.Data.SqlClient.SqlDataAdapter($SqlCommand)
        $data_table   = New-Object System.Data.DataTable
        $data_adapter.Fill($data_table) | Out-Null

        # Output data
        $data_table.Rows

        $data_table.Dispose()
        $data_adapter.Dispose()
    }

    # Non-streaming (data stored in $data_set)
    function Invoke-MsSqlCommand-DataAdapter-DataSet {
        param (
            [System.Data.SqlClient.SqlCommand] $SqlCommand
        )

        $data_adapter = New-Object System.Data.SqlClient.SqlDataAdapter($SqlCommand)
        $data_set     = New-Object System.Data.DataSet
        $data_adapter.Fill($data_set) | Out-Null

        # Output data
        $data_set.Tables[0]

        $data_set.Dispose()
        $data_adapter.Dispose()
    }

    if (! $DeParamCommand) {
        $DeParamCommand = DeParam-MsSqlCommand $SqlCommand
    }

    Log debug $DeParamCommand

    try {
        Invoke-MsSqlCommand-ExecuteReader $SqlCommand
    }
    catch {
        Log error "Failed: $_"
        Write-Error $_
    }

    Log debug "Done"
}


function Open-MsSqlConnection {
    param (
        [string] $ConnectionParams
    )

    $connection_params = ConvertFrom-Json2 $ConnectionParams

    $cs_builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder

    # Use connection related parameters only
    $cs_builder['Data Source']     = $connection_params.server
    $cs_builder['Initial Catalog'] = $connection_params.database

    if ($connection_params.use_svc_account_creds) {
        $cs_builder['Integrated Security'] = 'SSPI'
    }
    else {
        $cs_builder['User ID']  = $connection_params.username
        $cs_builder['Password'] = $connection_params.password
    }

    $connection_string = $cs_builder.ConnectionString

    if ($Global:MsSqlConnection -and $connection_string -ne $Global:MsSqlConnectionString) {
        Log info "MsSqlConnection connection parameters changed"
        Close-MsSqlConnection
    }

    if ($Global:MsSqlConnection -and $Global:MsSqlConnection.State -ne 'Open') {
        Log warn "MsSqlConnection State is '$($Global:MsSqlConnection.State)'"
        Close-MsSqlConnection
    }

    if ($Global:MsSqlConnection) {
        #Log debug "Reusing MsSqlConnection"
    }
    else {
        Log info "Opening MsSqlConnection '$connection_string'"

        try {
            $connection = New-Object System.Data.SqlClient.SqlConnection($connection_string)
            $connection.Open()

            $Global:MsSqlConnection       = $connection
            $Global:MsSqlConnectionString = $connection_string

            $Global:ColumnsInfoCache = @{}
            $Global:SqlInfoCache = @{}
        }
        catch {
            Log error "Failed: $_"
            Write-Error $_
        }

        Log info "Done"
    }
}


function Close-MsSqlConnection {
    if ($Global:MsSqlConnection) {
        Log info "Closing MsSqlConnection"

        try {
            $Global:MsSqlConnection.Close()
            $Global:MsSqlConnection = $null
        }
        catch {
            # Purposely ignoring errors
        }

        Log info "Done"
    }
}
