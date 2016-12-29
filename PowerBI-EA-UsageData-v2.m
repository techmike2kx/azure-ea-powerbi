let
    Source = AzureEnterprise.Tables("https://ea.azure.com/rest/123456"),
    Detail = Source{[Key="Detail"]}[Data],
    //duplicating this column so that we don't touch the original
    #"Setup: Duplicated Column" = Table.DuplicateColumn(Detail, "Name", "Year-Month"),
    //change the type to date so that we can do some date filtering on it
    #"Setup: Changed Type" = Table.TransformColumnTypes(#"Setup: Duplicated Column",{{"Year-Month", type date}}),
    // We are only keeping data from the past 12 months in scope, set this to 1 if you want to do some editting as it will apply faster, set to 11 to have 12 months as the current month counts as 1 as well
    #"Setup: Filtered Rows" = Table.SelectRows(#"Setup: Changed Type", each Date.IsInPreviousNMonths([#"Year-Month"], 11) or Date.IsInCurrentMonth([#"Year-Month"])),
    //we're going to store the data column in a temporary variable
    #"Data: Content" = Table.Column(#"Setup: Filtered Rows", "Data"),
    //we're looping over all tables to get a list of all columnnames
    #"Data: ColumNames" = List.Distinct(List.Combine(List.Transform(#"Data: Content", 
                        each Table.ColumnNames(_)))),
    //using the list of columnnames we can now expand the data
    #"Data: Expanded Data" = Table.ExpandTableColumn(#"Setup: Filtered Rows", "Data",#"Data: ColumNames",#"Data: ColumNames"),
    //the line below is an alternative approach. This is the code that is generated by clicking the expand button on a column. 
    //#"Data: Expanded Data" = Table.ExpandTableColumn(#"Setup: Filtered Rows", "Data", {"AccountOwnerId", "Account Name", "ServiceAdministratorId", "SubscriptionId", "SubscriptionGuid", "Subscription Name", "Date", "Month", "Day", "Year", "Product", "Meter ID", "Meter Category", "Meter Sub-Category", "Meter Region", "Meter Name", "Consumed Quantity", "ResourceRate", "ExtendedCost", "Resource Location", "Consumed Service", "Instance ID", "ServiceInfo1", "ServiceInfo2", "AdditionalInfo", "Tags", "Store Service Identifier", "Department Name", "Cost Center", "Unit Of Measure", "Resource Group", ""}, {"AccountOwnerId", "Account Name", "ServiceAdministratorId", "SubscriptionId", "SubscriptionGuid", "Subscription Name", "Date", "Month", "Day", "Year", "Product", "Meter ID", "Meter Category", "Meter Sub-Category", "Meter Region", "Meter Name", "Consumed Quantity", "ResourceRate", "ExtendedCost", "Resource Location", "Consumed Service", "Instance ID", "ServiceInfo1", "ServiceInfo2", "AdditionalInfo", "Tags", "Store Service Identifier", "Department Name", "Cost Center", "Unit Of Measure", "Resource Group", ""}),
    //we only need to change the type for non-text columns
    #"Setup: Changed Type Localized" = Table.TransformColumnTypes(#"Data: Expanded Data",{{"SubscriptionId", Int64.Type}, {"Month", Int64.Type}, {"Day", Int64.Type}, {"Year", Int64.Type}, {"Consumed Quantity", type number}, {"ResourceRate", type number},{"Date", type date},{"ExtendedCost", type number}},"en-US"),
    // in some cases we end up with some empty rows, we only want to keep the rows with actual data (e.g. subscription guid being present)
    #"Setup: Filter Empty Rows" = Table.SelectRows(#"Setup: Changed Type Localized", each [SubscriptionGuid] <> null),    
    //further down we'll expand the Tags column. In order to keep the original column we'll take a copy of it first
    #"Tags: Duplicated Column" = Table.DuplicateColumn(#"Setup: Filter Empty Rows", "Tags", "Tags - Copy"),
    //We need to pouplate the empty json tag {} for values that are blank
    #"Tags: Replace Empty Value" = Table.ReplaceValue(#"Tags: Duplicated Column","","{}",Replacer.ReplaceValue,{"Tags - Copy"}),
    //sometimes tags might have different casings due to erroneous input (e.g. Environment and environment). Here we convert them to Proper casing
    #"Tags: Capitalized Each Word" = Table.TransformColumns(#"Tags: Replace Empty Value",{{"Tags - Copy", Text.Proper}}),    
    //convert the content of the Tags column to JSON records
    #"Tags: in JSON" = Table.TransformColumns(#"Tags: Capitalized Each Word",{{"Tags - Copy", Json.Document}}),
    //The next steps will determine a list of columns that need to be added and populated
    //the idea is to have a column for each tag key type
    //take the Tags column in a temp list variable
    //source of inspiration: https://blog.crossjoin.co.uk/2014/05/21/expanding-all-columns-in-a-table-in-power-query/
    #"Tags: Content" = Table.Column(#"Tags: in JSON", "Tags - Copy"),
    //for each of the Tags: take the fieldnames (key names) and add them to a list while removing duplicates
    #"Tags: FieldNames" = List.Distinct(List.Combine(List.Transform(#"Tags: Content", 
                        each Record.FieldNames(_)))),
    //this is the list of the actual column names. We're prepending Tag.'
    #"Tags: New Column Names" = List.Transform(#"Tags: FieldNames", each "Tag." & _),    
    //expand the JSON records using the fieldnames (keys) to new column names list mapping
    #"Tags: Expanded" = Table.ExpandRecordColumn(#"Tags: in JSON", "Tags - Copy", #"Tags: FieldNames",#"Tags: New Column Names"),
    //create a column with the consumption date (instead of 3 separate columns)    
    #"Consumption Date: Added Column" = Table.AddColumn(#"Tags: Expanded", "ConsumptionDate", each Text.From([Month])&"/"&Text.From([Day])&"/"&Text.From([Year])),
    #"Consumption Date: Change to Date Type" = Table.TransformColumnTypes(#"Consumption Date: Added Column",{{"ConsumptionDate", type date}},"en-US"),
    //create a column with the amount of days ago the usage happened
    #"Date Difference: Added Column" = Table.AddColumn(#"Consumption Date: Change to Date Type", "DateDifference", each Duration.Days(Duration.From(DateTime.Date(DateTime.LocalNow())- [ConsumptionDate]))),
    #"Date Difference: Changed to Number Type" = Table.TransformColumnTypes(#"Date Difference: Added Column",{{"DateDifference", type number}}),
    //create a friendly name for resource (as an alternative to the instance ID which is quite long)
    #"Resource Name: Duplicate Instance ID" = Table.DuplicateColumn(#"Date Difference: Changed to Number Type", "Instance ID", "Instance ID-TEMP"),
    #"Resource Name: Split Column" = Table.SplitColumn(#"Resource Name: Duplicate Instance ID","Instance ID-TEMP",Splitter.SplitTextByEachDelimiter({"/"}, QuoteStyle.Csv, true),{"Instance ID.1", "Instance ID.2"}),
    #"Resource Name: Construct Column" = Table.AddColumn(#"Resource Name: Split Column", "Resource Name", each if [Instance ID.2] = null then [Instance ID.1] else [Instance ID.2] ),
    #"Cleanup: Removed Undesired Columns" = Table.RemoveColumns(#"Resource Name: Construct Column",{"Instance ID.1", "Instance ID.2", "AccountOwnerId", "Account Name", "ServiceAdministratorId", "Link", "Report", "ItemKind", "ItemName", "IsLeaf", "SubscriptionId", ""})
in
    #"Cleanup: Removed Undesired Columns"