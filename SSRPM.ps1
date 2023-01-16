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


function Compose-SqlCommand-SelectColumnsInfo {
    param (
        [string] $Table
    )

    "
        SELECT
    	    sc.name AS column_name,
    	    CAST(CASE WHEN pk.COLUMN_NAME IS NULL THEN 0 ELSE 1 END AS BIT) AS is_primary_key,
    	    sc.is_identity,
    	    sc.is_computed,
    	    sc.is_nullable
        FROM
        	sys.schemas AS ss
    	    INNER JOIN sys.tables  AS st ON ss.schema_id = st.schema_id
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
        WHERE
        	ss.name + '.' + st.name = '$($Table -replace '\[|\]', '')'
    "
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

            $tables = Invoke-MsSqlCommand "
                SELECT
                    TABLE_SCHEMA + '.[' + TABLE_NAME + ']' AS [Name],
                    (CASE WHEN TABLE_TYPE = 'BASE TABLE' THEN 'Table' WHEN TABLE_TYPE = 'VIEW' THEN 'View' ELSE 'Unknown' END) AS [Type]
                FROM
                    INFORMATION_SCHEMA.TABLES
                ORDER BY
                    [Name]
            "

            #
            # Output list of supported operations per table/view (named Class)
            #

            @(
                foreach ($t in $tables) {
                    $columns = Invoke-MsSqlCommand (Compose-SqlCommand-SelectColumnsInfo $t.Name)
                    $primary_key = @($columns | Where-Object { $_.is_primary_key } | ForEach-Object { $_.column_name })[0]

                    if ($t.Type -ne 'Table') {
                        # Non-tables only support 'Read'
                        [ordered]@{
                            Class = $t.Name
                            Operation = 'Read'
                            'Source type' = $t.Type
                            'Primary key' = $primary_key
                            'Supported operations' = 'R'
                        }
                    }
                    else {
                        <#[ordered]@{
                            Class = $t.Name
                            Operation = 'Create'
                        }#>

                        [ordered]@{
                            Class = $t.Name
                            Operation = 'Read'
                            'Source type' = $t.Type
                            'Primary key' = $primary_key
                            'Supported operations' = "CR$(if ($primary_key) { 'UD' } else { '' })"
                        }

                        <#if ($primary_key) {
                            # Only supported if primary key is present
                            [ordered]@{
                                Class = $t.Name
                                Operation = 'Update'
                            }

                            [ordered]@{
                                Class = $t.Name
                                Operation = 'Delete'
                            }
                        }#>
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

            $columns = Invoke-MsSqlCommand (Compose-SqlCommand-SelectColumnsInfo $Class)

            switch ($Operation) {
                'Create' {
                    @{
                        semantics = 'create'
                        parameters = @(
                            $columns | ForEach-Object {
                                @{
                                    name = $_.column_name;
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
                                        name = $_.column_name
                                        config = @(
                                            if ($_.is_primary_key) { 'Primary key' }
                                            if ($_.is_identity)    { 'Auto identity' }
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
                            value = @($columns | ForEach-Object { $_.column_name })
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
                                    name = $_.column_name;
                                    allowance = if ($_.is_primary_key) { 'mandatory' } else { 'optional' }
                                }
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
                                        name = $_.column_name
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
                $columns = Invoke-MsSqlCommand (Compose-SqlCommand-SelectColumnsInfo $Class)

                $Global:ColumnsInfoCache[$Class] = @{
                    primary_key  = @($columns | Where-Object { $_.is_primary_key } | ForEach-Object { $_.column_name })[0]
                    identity_col = @($columns | Where-Object { $_.is_identity    } | ForEach-Object { $_.column_name })[0]
                }
            }

            $primary_key  = $Global:ColumnsInfoCache[$Class].primary_key
            $identity_col = $Global:ColumnsInfoCache[$Class].identity_col

            $function_params = ConvertFrom-Json2 $FunctionParams

            $command = $null

            $projection = if ($function_params['selected_columns'].count -eq 0) { '*' } else { @($function_params['selected_columns'] | ForEach-Object { "[$_]" }) -join ', ' }

            switch ($Operation) {
                'Create' {
                    $selection = if ($identity_col) {
                                     "[$identity_col] = SCOPE_IDENTITY()"
                                 }
                                 elseif ($primary_key) {
                                     "[$primary_key] = '$($function_params[$primary_key])'"
                                 }
                                 else {
                                     @($function_params.Keys | ForEach-Object { "[$_] = '$($function_params[$_])'" }) -join ' AND '
                                 }

                    $command = "INSERT INTO $Class ($(@($function_params.Keys | ForEach-Object { "[$_]" }) -join ', ')) VALUES ($(@($function_params.Keys | ForEach-Object { "$(if ($function_params[$_] -ne $null) { "'$($function_params[$_])'" } else { 'null' })" }) -join ', ')); SELECT TOP(1) $projection FROM $Class WHERE $selection"
                    break
                }

                'Read' {
                    $selection = if ($function_params['where_clause'].length -eq 0) { '' } else { " WHERE $($function_params['where_clause'])" }

                    $command = "SELECT $projection FROM $Class$selection"
                    break
                }

                'Update' {
                    $command = "UPDATE TOP(1) $Class SET $(@($function_params.Keys | ForEach-Object { if ($_ -ne $primary_key) { "[$_] = $(if ($function_params[$_] -ne $null) { "'$($function_params[$_])'" } else { 'null' })" } }) -join ', ') WHERE [$primary_key] = '$($function_params[$primary_key])'; SELECT TOP(1) [$primary_key], $(@($function_params.Keys | ForEach-Object { if ($_ -ne $primary_key) { "[$_]" } }) -join ', ') FROM $Class WHERE [$primary_key] = '$($function_params[$primary_key])'"
                    break
                }

                'Delete' {
                    $command = "DELETE TOP(1) $Class WHERE [$primary_key] = '$($function_params[$primary_key])'"
                    break
                }
            }

            if ($command) {
                LogIO info ($command -split ' ')[0] -In -Command $command

                if ($Operation -eq 'Read') {
                    # Streamed output
                    Invoke-MsSqlCommand $command
                }
                else {
                    # Log output
                    $rv = Invoke-MsSqlCommand $command
                    LogIO info ($command -split ' ')[0] -Out $rv

                    $rv
                }
            }

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

function Invoke-MsSqlCommand {
    param (
        [string] $Command
    )

    # Streaming
    # ERAM dbo.Files (426.977 rows) execution time: ?
    function Invoke-MsSqlCommand-ExecuteReader {
        param (
            [string] $Command
        )

        $sql_command = New-Object System.Data.SqlClient.SqlCommand($Command, $Global:MsSqlConnection)
        $data_reader = $sql_command.ExecuteReader()
        $column_names = @($data_reader.GetSchemaTable().ColumnName)

        if ($column_names) {

            # Read data
            while ($data_reader.Read()) {
                $hash_table = [ordered]@{}

                foreach ($column_name in $column_names) {
                    $hash_table[$column_name] = if ($data_reader[$column_name] -is [System.DBNull]) { $null } else { $data_reader[$column_name] }
                }

                # Output data
                [PSCustomObject]$hash_table
            }

        }

        $data_reader.Close()
        $sql_command.Dispose()
    }

    # Streaming
    # ERAM dbo.Files (426.977 rows) execution time: 16.7 s
    function Invoke-MsSqlCommand-ExecuteReader00 {
        param (
            [string] $Command
        )

        $sql_command = New-Object System.Data.SqlClient.SqlCommand($Command, $Global:MsSqlConnection)
        $data_reader = $sql_command.ExecuteReader()
        $column_names = @($data_reader.GetSchemaTable().ColumnName)

        if ($column_names) {

            # Initialize result
            $hash_table = [ordered]@{}

            for ($i = 0; $i -lt $column_names.Count; $i++) {
                $hash_table[$column_names[$i]] = ''
            }

            $result = [PSCustomObject]$hash_table

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
        $sql_command.Dispose()
    }

    # Streaming
    # ERAM dbo.Files (426.977 rows) execution time: 01:11.9 s
    function Invoke-MsSqlCommand-ExecuteReader01 {
        param (
            [string] $Command
        )

        $sql_command = New-Object System.Data.SqlClient.SqlCommand($Command, $Global:MsSqlConnection)
        $data_reader = $sql_command.ExecuteReader()
        $field_count = $data_reader.FieldCount

        while ($data_reader.Read()) {
            $hash_table = [ordered]@{}
        
            for ($i = 0; $i -lt $field_count; $i++) {
                $hash_table[$data_reader.GetName($i)] = $data_reader.GetValue($i)
            }

            # Output data
            [PSCustomObject]$hash_table
        }

        $data_reader.Close()
        $sql_command.Dispose()
    }

    # Non-streaming (data stored in $data_table)
    # ERAM dbo.Files (426.977 rows) execution time: 15.5 s
    function Invoke-MsSqlCommand-DataAdapter-DataTable {
        param (
            [string] $Command
        )

        $sql_command  = New-Object System.Data.SqlClient.SqlCommand($Command, $Global:MsSqlConnection)
        $data_adapter = New-Object System.Data.SqlClient.SqlDataAdapter($sql_command)
        $data_table   = New-Object System.Data.DataTable
        $data_adapter.Fill($data_table) | Out-Null

        # Output data
        $data_table.Rows

        $data_table.Dispose()
        $data_adapter.Dispose()
        $sql_command.Dispose()
    }

    # Non-streaming (data stored in $data_set)
    # ERAM dbo.Files (426.977 rows) execution time: 14.8 s
    function Invoke-MsSqlCommand-DataAdapter-DataSet {
        param (
            [string] $Command
        )

        $sql_command  = New-Object System.Data.SqlClient.SqlCommand($Command, $Global:MsSqlConnection)
        $data_adapter = New-Object System.Data.SqlClient.SqlDataAdapter($sql_command)
        $data_set     = New-Object System.Data.DataSet
        $data_adapter.Fill($data_set) | Out-Null

        # Output data
        $data_set.Tables[0]

        $data_set.Dispose()
        $data_adapter.Dispose()
        $sql_command.Dispose()
    }

    $Command = ($Command -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ' '

    Log debug $Command

    try {
        Invoke-MsSqlCommand-ExecuteReader $Command
    }
    catch {
        Log error "Failed: $_"
        Write-Error $_
    }
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
