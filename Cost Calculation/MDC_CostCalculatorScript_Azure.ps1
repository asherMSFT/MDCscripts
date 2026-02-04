#Requires -Version 7.0
# Ensure strict mode is enabled for catching common issues
Set-StrictMode -Version Latest

# Ensure you're logged in
$accountInfo = $null
try {
    $accountInfo = Get-AzContext
    if (-not $accountInfo) {
        $accountInfo = Connect-AzAccount
        if (-not $accountInfo) {
            throw "Failed to log in to Azure."
        }
    }
} catch {
    Write-Error "Failed to log in to Azure. Please ensure you have the Az PowerShell module installed and internet access. Error: $_"
    exit
}

# Retrieve all subscriptions the user has access to
try {
    $subscriptions = Get-AzSubscription -TenantId $accountInfo.Tenant.Id
    if (-not $subscriptions) {
         throw "No subscriptions found."
    }
} catch {
    Write-Error "Failed to retrieve subscriptions. Error: $_"
    exit
}

$environmentType = "Azure"

# Initialize a list to hold results for all subscriptions
$allSubscriptionsResults = @()

# Run the Azure Resource Graph query for all subscriptions at once
$query = "(securityresources
        | extend type = tolower(type)
        | where type == 'microsoft.security/assessments'
        | where name == '44d12760-2cf2-4e6d-8613-8451c11c1abc' 
        | extend bundleName = 'virtualmachines'
        | summarize resourcesCount = count() by subscriptionId, bundleName
        )
        | union 
        (resources
        | extend type = tolower(type)
        | where type in ('microsoft.compute/virtualmachines', 'microsoft.classiccompute/virtualmachines', 'microsoft.hybridcompute/machines', 'microsoft.compute/virtualmachinescalesets', 'microsoft.sql/servers', 'microsoft.storage/storageaccounts', 'microsoft.documentdb/databaseaccounts', 'microsoft.containerregistry/registries', 'microsoft.keyvault/vaults', 'microsoft.web/serverfarms', 'microsoft.dbforpostgresql/servers', 'microsoft.dbforpostgresql/flexibleservers', 'microsoft.dbformysql/servers', 'microsoft.dbformysql/flexibleservers', 'microsoft.dbformariadb/servers', 'microsoft.apimanagement/service', 'microsoft.sqlvirtualmachine/sqlvirtualmachines', 'microsoft.azurearcdata/sqlserverinstances', 'microsoft.cognitiveservices/accounts', 'microsoft.web/sites')
        | parse id with '/subscriptions/'subscriptionId'/'rest
         | extend bundleCount = 0, bundleName = pack_array('')
        | extend bundleCount = iff(type in ('microsoft.compute/virtualmachines','microsoft.classiccompute/virtualmachines'), 1 , bundleCount), bundleName  = iff(type in ('microsoft.compute/virtualmachines','microsoft.classiccompute/virtualmachines'), pack_array('virtualmachines', 'cloudposture'), bundleName)
        | extend bundleCount = iff(type == 'microsoft.hybridcompute/machines', 1 , bundleCount), bundleName  = iff(type == 'microsoft.hybridcompute/machines', pack_array('virtualmachines'), bundleName)
        | extend bundleCount = iff(type == 'microsoft.compute/virtualmachinescalesets' and sku != '' and sku.capacity != '', toint(sku.capacity),  bundleCount), bundleName = iff(type =~ 'microsoft.compute/virtualmachinescalesets' and sku != '' and sku.capacity != '', pack_array('virtualmachines', 'cloudposture'),  bundleName)
        | extend bundleCount = iff(type == 'microsoft.storage/storageaccounts', 1 ,  bundleCount), bundleName = iff(type == 'microsoft.storage/storageaccounts', pack_array('storageaccounts', 'cloudposture') ,  bundleName)
        | extend bundleCount = iff(type == 'microsoft.containerregistry/registries', 1 ,  bundleCount), bundleName = iff(type == 'microsoft.containerregistry/registries', pack_array('containers', 'containerregistry') ,  bundleName)
        | extend bundleCount = iff(type == 'microsoft.keyvault/vaults', 1 ,  bundleCount), bundleName = iff(type == 'microsoft.keyvault/vaults', pack_array('keyvaults'),  bundleName)
        | extend bundleCount = iff(type == 'microsoft.web/serverfarms' and isnotempty(sku) and tolower(sku.tier) != 'consumption', toint(properties.numberOfWorkers),  bundleCount), bundleName = iff(type == 'microsoft.web/serverfarms' and isnotempty(sku) and tolower(sku.tier) != 'consumption', pack_array('appservices'),  bundleName)
        | extend bundleCount = iff((type == 'microsoft.dbforpostgresql/servers' or type == 'microsoft.dbforpostgresql/flexibleservers' or type == 'microsoft.dbformysql/servers' or type == 'microsoft.dbformysql/flexibleservers' or type == 'microsoft.dbformariadb/servers') and sku.tier !contains('basic'),  1, bundleCount), bundleName = iff((type =~ 'microsoft.dbforpostgresql/servers' or type =~ 'microsoft.dbforpostgresql/flexibleservers' or type =~ 'microsoft.dbformysql/servers' or type =~ 'microsoft.dbformysql/flexibleservers' or type =~ 'microsoft.dbformariadb/servers') and sku.tier !contains('basic'), pack_array('opensourcerelationaldatabases', 'cloudposture'),  bundleName)
        | extend bundleCount = iff(type == 'microsoft.documentdb/databaseaccounts', 1 ,  bundleCount), bundleName = iff(type == 'microsoft.documentdb/databaseaccounts', pack_array('cosmosdbs') ,  bundleName)
        | extend bundleCount = iff(type == 'microsoft.apimanagement/service', 1 ,  bundleCount), bundleName = iff(type == 'microsoft.apimanagement/service', pack_array('api') ,  bundleName)
        | extend bundleCount = iff(type == 'microsoft.sql/servers', 1 ,  bundleCount), bundleName = iff(type == 'microsoft.sql/servers', pack_array('sqlservers', 'cloudposture') ,  bundleName)
        | extend bundleCount = iff(type == 'microsoft.sqlvirtualmachine/sqlvirtualmachines' or type == 'microsoft.azurearcdata/sqlserverinstances', 1 , bundleCount), bundleName = iff(type == 'microsoft.sqlvirtualmachine/sqlvirtualmachines' or type == 'microsoft.azurearcdata/sqlserverinstances', pack_array('sqlservervirtualmachines') , bundleName)
        | extend bundleCount = iff(type == 'microsoft.cognitiveservices/accounts' and kind in ('OpenAI', 'AIServices'), 1 , bundleCount), bundleName = iff(type == 'microsoft.cognitiveservices/accounts' and kind in ('OpenAI', 'AIServices'), pack_array('ai') , bundleName)
        | extend bundleCount = iff(type == 'microsoft.web/sites', 1 , bundleCount), bundleName = iff(type == 'microsoft.web/sites', pack_array('serverless') , bundleName)
        | mv-expand bundleName to typeof(string) limit 2000
        | summarize resourcesCount = sum(bundleCount) by bundleName, subscriptionId
        | where bundleName != ''
        )
        | summarize resourcesCount = sum(resourcesCount) by bundleName, subscriptionId
    | project resourcesCount, subscriptionId, planName = bundleName"

try {
    $queryResults = @()
    $pageSize = 1000
    $skipToken = $null

    while ($true) {
        if ($skipToken) {
            $pagedResults = Search-AzGraph -Query $query -First $pageSize -SkipToken $skipToken -UseTenantScope
        } else {
            $pagedResults = Search-AzGraph -Query $query -First $pageSize -UseTenantScope
        }

        if (-not $pagedResults) {
            throw "No resources found."
        }

        $queryResults += $pagedResults.Data
        $skipToken = $pagedResults.SkipToken

        if ($pagedResults.Data.Count -lt $pageSize) {
            break
        }
    }

    if (-not $queryResults) {
        throw "No resources found."
    }
} catch {
    Write-Error "Failed to retrieve resources using Azure Resource Graph. Error: $_"
    exit
}

# *** Collect numbers for resource based plans *** 

$hourBasedPlans = @("cloudposture", "serverless", "virtualmachines", "appservices", "sqlservers", "sqlservervirtualmachines", "opensourcerelationaldatabases", "storageaccounts", "keyvaults", "arm")

# Process the query results
foreach ($result in $queryResults) {
    $resourcesCount = $result.resourcesCount
    $planName = $result.planName
    $subscriptionId = $result.subscriptionId
    $subscriptionName = ($subscriptions | Where-Object { $_.Id -eq $subscriptionId }).Name

    Write-Host "Subscription: $subscriptionName, Resources Count: $resourcesCount, Plan Name: $planName"

    # Determine billable units based on the plan name
    $billableUnits = if ($hourBasedPlans -contains $planName.ToLower()) {
        730 # Assuming 730 hours in a month
    } else {
        0
    }    

    # Compile the subscription results
    $subscriptionResult = [PSCustomObject]@{
        SubscriptionID = $subscriptionId
        SubscriptionName = $subscriptionName
        ResourcesCount = $resourcesCount
        BillableUnits = $billableUnits
        PlanName = $planName
        EnvironmentType = $environmentType
        RecommendedSubPlan = $null
        ExcludableResources = $null
    }

    # Add this subscription's results to the list
    $allSubscriptionsResults += $subscriptionResult
}

# Run the additional query to retrieve serversCount for virtual machine scale sets
$aksServersQuery = @"
resources
            | where type == "microsoft.compute/virtualmachinescalesets"
            | where isnotempty(sku) and name startswith "aks-"
            | extend capacity = tostring(sku.capacity)
            | summarize serversCount = sum(toint(capacity)) by subscriptionId
"@

try {
    $aksServersQueryResults = @()
    $pageSize = 1000
    $skipToken = $null

    while ($true) {
        if ($skipToken) {
            $pagedResults = Search-AzGraph -Query $aksServersQuery -First $pageSize -SkipToken $skipToken -UseTenantScope
        } else {
            $pagedResults = Search-AzGraph -Query $aksServersQuery -First $pageSize -UseTenantScope
        }

        if (-not $pagedResults) {
            throw "No AKS VM scale sets found."
        }

        $aksServersQueryResults += $pagedResults.Data
        $skipToken = $pagedResults.SkipToken

        if ($pagedResults.Data.Count -lt $pageSize) {
            break
        }
    }

    if (-not $aksServersQueryResults) {
        throw "No AKS VM scale sets found."
    }

    # Enrich the ExcludableResources property for rows with plan 'virtualmachines'
    foreach ($subscriptionResult in $allSubscriptionsResults) {
        if ($subscriptionResult.PlanName -eq "virtualmachines") {
            $subscriptionId = $subscriptionResult.SubscriptionID
            $vmScaleSetResult = $aksServersQueryResults | Where-Object { $_.subscriptionId -eq $subscriptionId }

            if ($vmScaleSetResult) {
                $serversCount = $vmScaleSetResult.serversCount
                $subscriptionResult.ExcludableResources = $serversCount
            } else {
                $subscriptionResult.ExcludableResources = 0
            }

            Write-Host "Subscription: $($subscriptionResult.SubscriptionName), Excludable Resources (AKS servers): $($subscriptionResult.ExcludableResources)"
        }
    }
} catch {
    Write-Error "Failed to retrieve AKS VM scale sets using Azure Resource Graph. Error: $_"
    foreach ($subscriptionResult in $allSubscriptionsResults) {
        if ($subscriptionResult.PlanName -eq "virtualmachines") {
            $subscriptionResult.ExcludableResources = 0
        }
    }
}

# Run the Azure Resource Graph query to collect VM cores for 'containers' plan
$containersQuery = @"
resources
            | extend managedClustersCount = iff(type == "microsoft.containerservice/managedclusters" and isnotempty(sku) and tolower(sku.tier) != "consumption", toint(properties.numberOfWorkers), 0)
            | where tostring(properties.powerState.code) =~ 'Running'
            | mv-expand properties.agentPoolProfiles
            | extend sku = tostring(properties_agentPoolProfiles.vmSize)
            | parse kind=regex sku with '(.*?)_([A-Za-z]*)' coresInSku: int '([A-Za-z]*)_(.*?)'
            | project subscriptionId, resourceGroup, managedClustersCount = toint(properties_agentPoolProfiles['count']) * coresInSku
            | summarize coresCount=sum(managedClustersCount) by subscriptionId
            | union (
                resources
                | where tolower(type) =~ "microsoft.kubernetes/connectedclusters"
                | parse id with "/subscriptions/" subscriptionId "/"rest
                | extend coreCount = toint(properties.totalCoreCount)
                | summarize coresCount=sum(coreCount) by subscriptionId
            )
            | summarize vmCoresCount=sum(coresCount) by subscriptionId
"@

try {
    $containersQueryResults = @()
    $pageSize = 1000
    $skipToken = $null

    while ($true) {
        if ($skipToken) {
            $pagedResults = Search-AzGraph -Query $containersQuery -First $pageSize -SkipToken $skipToken -UseTenantScope
        } else {
            $pagedResults = Search-AzGraph -Query $containersQuery -First $pageSize -UseTenantScope
        }

        if (-not $pagedResults) {
            throw "No VM cores found."
        }

        $containersQueryResults += $pagedResults.Data
        $skipToken = $pagedResults.SkipToken

        if ($pagedResults.Data.Count -lt $pageSize) {
            break
        }
    }

    if (-not $containersQueryResults) {
        throw "No VM cores found."
    }

    # Update the BillableUnits for each subscription in allSubscriptionsResults based on containersQueryResults
    foreach ($subscriptionResult in $allSubscriptionsResults) {
        if ($subscriptionResult.PlanName -eq "containers") {
            $subscriptionId = $subscriptionResult.SubscriptionID
            $vmCoresCount = 0
            $containerResult = $containersQueryResults | Where-Object { $_.subscriptionId -eq $subscriptionId }

            if ($containerResult) {
                $vmCoresCount = $containerResult.vmCoresCount
                $subscriptionResult.BillableUnits = $vmCoresCount
            } else {
                $subscriptionResult.BillableUnits = 0
            }

            Write-Host "Subscription: $($subscriptionResult.SubscriptionName), VM Cores Count: $vmCoresCount"
        }
    }
} catch {
    Write-Error "Failed to retrieve VM cores using Azure Resource Graph. Error: $_"
    foreach ($subscriptionResult in $allSubscriptionsResults) {
        if ($subscriptionResult.PlanName -eq "containers") {
            $subscriptionResult.BillableUnits = 0
        }
    }
}

# Add an item to allSubscriptionsResults for plan "arm" with ResourcesCount = 1 for each subscription
foreach ($sub in $subscriptions) {
    # Remove existing items for "arm" before appending
    $allSubscriptionsResults = $allSubscriptionsResults | Where-Object { $_.PlanName -ne "arm" -or $_.SubscriptionID -ne $sub.Id }

    # Compile the subscription results
    $subscriptionResult = [PSCustomObject]@{
        SubscriptionID = $sub.Id
        SubscriptionName = $sub.Name
        ResourcesCount = 1
        BillableUnits = 730 # Assuming 730 hours in a month
        PlanName = "arm"
        EnvironmentType = $environmentType
    }

    # Add this subscription's results to the list
    $allSubscriptionsResults += $subscriptionResult
}

# Prompt the user to confirm if they want to run the additional data collection
$runAdditionalDataCollection = Read-Host "Do you want to run the additional data collection for API, Cosmos DB, and Malware Scanning (storage) plans? Collection of this data can take longer dpending on the size of your environment. (yes/no)"

if ($runAdditionalDataCollection -eq "yes") {
    # Collect data for containers plan - based on allocation metric over time for more accureate estimate
    foreach ($sub in $subscriptions) {
        Write-Host "Processing Subscription: $($sub.Name) - $($sub.Id) for containers plan"

        # Initialize variables to hold the total VPU cores and the number of clusters for the current subscription
        $totalVPUCoresForSubscription = 0
        $clustersCount = 0

        # Get all AKS clusters in the subscription
        try {
            $aksClustersUri = "/subscriptions/$($sub.Id)/providers/Microsoft.ContainerService/managedClusters?api-version=2021-03-01"
            $response = Invoke-AzRestMethod -Method GET -Path $aksClustersUri -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $aksClusters = $response.Content | ConvertFrom-Json | Select-Object -ExpandProperty value
            } else {
                Write-Error "Failed to retrieve AKS clusters. Status code: $($response.StatusCode)"
                continue
            }

            if (-not $aksClusters) {
                Write-Host "No AKS clusters found in Subscription: $($sub.Name)"
                continue
            }
            $clustersCount = ($aksClusters | Measure-Object).Count
        } catch {
            Write-Error "Failed to retrieve AKS clusters in Subscription: $($sub.Name). Error: $_"
            continue # Continue with the next subscription if this fails
        }

        # Define the time range for the last 30 days
        $startTime = (Get-Date).AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

        foreach ($aks in $aksClusters) {
            $resourceId = $aks.Id
            Write-Host "AKS Cluster: $($resourceId)"

            try {
                $metrics = Get-AzMetric -ResourceId $resourceId -MetricName "kube_node_status_allocatable_cpu_cores" -StartTime $startTime -EndTime $endTime -AggregationType Average -TimeGrain 01:00:00
                if ($metrics -ne $null -and $metrics.Data -ne $null) {
                    $averageVPUCores = ($metrics.Data | Measure-Object Average -Average).Average
                    Write-Host "Average allocated CPU cores for the past 30 days: $averageVPUCores"
                    $totalVPUCoresForSubscription += $averageVPUCores
                } else {
                    Write-Host "No data available for allocated CPU cores metric for the past 30 days."
                }
            } catch {
                Write-Host "Error retrieving allocated CPU cores metric: $_"
            }
        }

        Write-Host "Total VPU cores for the subscription over the past 30 days: $totalVPUCoresForSubscription"

        # Remove existing items for "containers" before appending
        $allSubscriptionsResults = $allSubscriptionsResults | Where-Object { $_.PlanName -ne "containers" -or $_.SubscriptionID -ne $sub.Id }

        # Compile the subscription results
        $subscriptionResult = [PSCustomObject]@{
            SubscriptionID = $sub.Id
            SubscriptionName = $sub.Name
            ResourcesCount = $clustersCount
            BillableUnits = $totalVPUCoresForSubscription
            PlanName = "containers"
            EnvironmentType = $environmentType
        }

        # Add this subscription's results to the list
        $allSubscriptionsResults += $subscriptionResult
    }

    # *** Collect numbers for API plan ***

    foreach ($sub in $subscriptions) {
        Write-Host "Processing Subscription: $($sub.Name) - $($sub.Id) for API plan"

        # Get all APIM services in the subscription
        try {
            $apimServicesUri = "/subscriptions/$($sub.Id)/providers/Microsoft.ApiManagement/service?api-version=2024-05-01"
            $response = Invoke-AzRestMethod -Method GET -Path $apimServicesUri -ErrorAction Stop
            $apimServices = $response.Content | ConvertFrom-Json | Select-Object -ExpandProperty value

            if (-not $apimServices) {
                Write-Host "No APIM services found in Subscription: $($sub.Name)"
                continue
            }
        } catch {
            Write-Error "Failed to retrieve APIM services in Subscription: $($sub.Name). Error: $_"
            continue # Continue with the next subscription if this fails
        }

        # Track the number of APIM services in the result
        $apimServicesCount = ($apimServices | Measure-Object).Count
        Write-Host "Number of APIM services in subscription $($sub.Name): $apimServicesCount"

        # Define the time range for the last 30 days
        $startTime = (Get-Date).AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

        # Initialize a variable to hold the total requests for the current subscription
        $totalRequestsForSubscription = 0

        foreach ($apim in $apimServices) {
            $resourceId = $apim.Id
            Write-Host "APIM Service: $($resourceId)"
            
            Write-Host "Retrieving 'Requests' metric for APIM Service: $($apim.Name)"
            try {
                $metrics = Get-AzMetric -ResourceId $resourceId -MetricName "Requests" -StartTime $startTime -EndTime $endTime -AggregationType Total
                if ($metrics -ne $null -and $metrics.Data -ne $null) {
                    $serviceRequests = ($metrics.Data | Measure-Object Total -Sum).Sum
                    Write-Host "Total 'Requests' for the past 30 days: $serviceRequests"
                    $totalRequestsForSubscription += $serviceRequests
                } else {
                    Write-Host "No data available for 'Requests' metric for the past 30 days."
                }
            } catch {
                Write-Host "Error retrieving 'Requests' metric: $_"
            }
        }

        Write-Host "Total 'Requests' for the subscription over the past 30 days: $totalRequestsForSubscription"

        # Calculate costs for each plan taking the limit into consideration
        # Assuming plan details remain the same, and calculation logic applies per subscription
        $plans = @(
            @{ Name = "P1"; Fixed = 200; Overage = 0.00020; Limit = 1000000 },
            @{ Name = "P2"; Fixed = 700; Overage = 0.00014; Limit = 5000000 },
            @{ Name = "P3"; Fixed = 5000; Overage = 0.00010; Limit = 50000000 },
            @{ Name = "P4"; Fixed = 7000; Overage = 0.00007; Limit = 100000000 },
            @{ Name = "P5"; Fixed = 50000; Overage = 0.00005; Limit = 1000000000 }
        )
        $results = @()
        foreach ($plan in $plans) {
            if ($totalRequestsForSubscription -lt $plan.Limit) {
                $totalCost = $plan.Fixed
            } else {
                $totalOverage = $totalRequestsForSubscription - $plan.Limit
                $totalCost = $plan.Fixed + ($totalOverage * $plan.Overage)
            }
            $results += [PSCustomObject]@{
                Plan = $plan.Name
                TotalCost = $totalCost
            }
        }
        # Find the plan with the lowest cost
        $recommendedPlan = $results | Sort-Object TotalCost | Select-Object -First 1
        
        # Remove existing items for "api" before appending
        $allSubscriptionsResults = $allSubscriptionsResults | Where-Object { $_.PlanName -ne "api" -or $_.SubscriptionID -ne $sub.Id }

        # Compile the subscription results
        $subscriptionResult = [PSCustomObject]@{
            SubscriptionID = $sub.Id
            SubscriptionName = $sub.Name
            ResourcesCount = $apimServicesCount
            BillableUnits = $totalRequestsForSubscription
            PlanName = "api"
            EnvironmentType = $environmentType
            RecommendedSubPlan = $recommendedPlan.Plan
        }

        # Add this subscription's results to the list
        $allSubscriptionsResults += $subscriptionResult
    }

    # *** Collect numbers for Cosmos DB plan ***

    foreach ($sub in $subscriptions) {
        Write-Host "Processing Subscription: $($sub.Name) - $($sub.Id) for Cosmos DB plan"

        # Initialize variables to hold the total RU/s and the number of Cosmos DB accounts for the current subscription
        $totalRUsForSubscription = 0
        $cosmosDBAccountsCount = 0

        # Get all Cosmos DB accounts in the subscription
        try {
            $cosmosDBAccountsUri = "/subscriptions/$($sub.Id)/providers/Microsoft.DocumentDB/databaseAccounts?api-version=2021-04-15"
            $response = Invoke-AzRestMethod -Method GET -Path $cosmosDBAccountsUri -ErrorAction Stop
            $cosmosDBAccounts = $response.Content | ConvertFrom-Json | Select-Object -ExpandProperty value

            if (-not $cosmosDBAccounts) {
                Write-Host "No Cosmos DB accounts found in Subscription: $($sub.Name)"
                continue
            }
            $cosmosDBAccountsCount = ($cosmosDBAccounts | Measure-Object).Count
        } catch {
            Write-Error "Failed to retrieve Cosmos DB accounts in Subscription: $($sub.Name). Error: $_"
            continue # Continue with the next subscription if this fails
        }

        # Define the time range for the last 30 days
        $startTime = (Get-Date).AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")    

        foreach ($cosmosDB in $cosmosDBAccounts) {
            $resourceId = $cosmosDB.Id
            Write-Host "Cosmos DB Account: $($resourceId)"

            try {
                $isServerless = $cosmosDB.properties.capabilities | Where-Object { $_.name -eq "EnableServerless" } | ForEach-Object { $true }

                if ($isServerless -eq $true) {
                    # Serverless mode
                    $metrics = Get-AzMetric -ResourceId $resourceId -MetricName "TotalRequestUnits" -StartTime $startTime -EndTime $endTime -AggregationType Total
                    if ($metrics -ne $null -and $metrics.Data -ne $null) {
                        $accountRUs = ($metrics.Data | Measure-Object Total -Sum).Sum
                        Write-Host "Total RUs for the past 30 days (Serverless): $accountRUs"
                        $accountRUs = $accountRUs * 0.00003125
                        Write-Host "RUs for the past 30 days (Serverless): $accountRUs"
                        $totalRUsForSubscription += $accountRUs
                    } else {
                        Write-Host "No data available for 'TotalRequestUnits' metric for the past 30 days."
                    }
                } else {
                    $databasesUri = "$resourceId/sqlDatabases?api-version=2021-04-15"
                    $databasesResponse = Invoke-AzRestMethod -Method GET -Path $databasesUri -ErrorAction Stop
                    $databases = $databasesResponse.Content | ConvertFrom-Json | Select-Object -ExpandProperty value

                    foreach ($database in $databases) {
                        $databaseId = $database.Id
                        try {
                            $throughputUri = "https://management.azure.com/$databaseId/throughputSettings/default?api-version=2023-03-01-preview"
                            $throughputResponse = Invoke-AzRestMethod -Method GET -Path $throughputUri -ErrorAction Stop

                            $throughputSettings = $null
                            if ($throughputResponse.StatusCode -eq 200) {
                                $throughputSettings = $throughputResponse.Content | ConvertFrom-Json
                            }

                            if ($throughputSettings -ne $null -and $throughputSettings.properties -ne $null) {
                                if ($throughputSettings.properties.resource -ne $null -and $throughputSettings.properties.resource.PSObject.Properties.Match("autoscaleSettings").Count -gt 0) {
                                    # Calculate RU consumption using TotalRequestUnits metric for the database
                                    $dimFilter = "$(New-AzMetricFilter -Dimension DatabaseName -Operator eq -Value $database.name)"
                                    $metrics = Get-AzMetric -ResourceId $resourceId -MetricName "TotalRequestUnits" -StartTime $startTime -EndTime $endTime -AggregationType Maximum -MetricFilter $dimFilter -TimeGrain 01:00:00
                                    if ($metrics -ne $null -and $metrics.Data -ne $null) {
                                        $accountRUs = ($metrics.Data | Measure-Object Maximum -Sum).Sum
                                        Write-Host "RUs for the past 30 days (Database): $accountRUs"
                                        $totalRUsForSubscription += $accountRUs
                                    } else {
                                        Write-Host "No data available for 'TotalRequestUnits' metric for the past 30 days."
                                    }
                                } elseif ($throughputSettings.properties.resource -ne $null -and $throughputSettings.properties.resource.throughput -ne $null) {
                                    # Database is in manual mode
                                    $throughput = $throughputSettings.properties.resource.throughput
                                    Write-Host "Provisioned throughput for database $($databaseId): $throughput"
                                    $totalRUsForSubscription += $throughput * 730
                                }
                            } elseif ($throughputResponse.StatusCode -eq 404) {
                                # Iterate over containers if database throughputSettings are not defined
                                $containersUri = "$databaseId/containers?api-version=2021-04-15"
                                $containersResponse = Invoke-AzRestMethod -Method GET -Path $containersUri -ErrorAction Stop
                                $containers = $containersResponse.Content | ConvertFrom-Json | Select-Object -ExpandProperty value

                                foreach ($container in $containers) {
                                    $containerId = $container.Id
                                    try {
                                        $resourceUri = "$containerId/throughputSettings/default"
                                        $response = Invoke-AzRestMethod -Method GET -Uri "https://management.azure.com$($resourceUri)?api-version=2023-03-01-preview"
                                        if ($response.StatusCode -eq 200) {
                                            $result = $response.Content | ConvertFrom-Json
                                        } else {
                                            continue
                                        }

                                        # Extract the provisioned throughput (RU/s)
                                        if ($null -ne $result.properties.resource -and $result.properties.resource.PSObject.Properties.Match("autoscaleSettings").Count -gt 0) {
                                            # Calculate RU consumption using TotalRequestUnits metric
                                            $dimFilter = "$(New-AzMetricFilter -Dimension DatabaseName -Operator eq -Value $database.name) and $(New-AzMetricFilter -Dimension CollectionName -Operator eq -Value $container.name)"
                                            $metrics = Get-AzMetric -ResourceId $resourceId -MetricName "TotalRequestUnits" -StartTime $startTime -EndTime $endTime -AggregationType Maximum -MetricFilter $dimFilter -TimeGrain 01:00:00
                                            if ($metrics -ne $null -and $metrics.Data -ne $null) {
                                                $accountRUs = ($metrics.Data | Measure-Object Maximum -Sum).Sum
                                                Write-Host "RUs for the past 30 days (Container): $accountRUs"
                                                $totalRUsForSubscription += $accountRUs
                                            } else {
                                                Write-Host "No data available for 'TotalRequestUnits' metric for the past 30 days."
                                            }
                                        } elseif ($result.properties.resource -ne $null -and $result.properties.resource.throughput -ne $null) {
                                            # Container is in manual mode
                                            $throughput = $result.properties.resource.throughput
                                            Write-Host "Provisioned throughput for container $($containerId): $throughput"
                                            $totalRUsForSubscription += $throughput * 730
                                        } else {
                                            Write-Host "No provisioned throughput data available for container $($containerId)."
                                        }
                                    } catch {
                                        Write-Host "Error retrieving throughput for container $($containerId): $_"
                                    }
                                }
                            }
                        } catch {
                            Write-Host "Error retrieving throughput settings for database $($databaseId): $_"
                        }
                    }
                }
            } catch {
                Write-Host "Error retrieving metrics for Cosmos DB Account: $_"
            }
        }

        # Calculate the average RUs per hour in units of RUs / hour
        $averageRUsPerHour = [math]::Round($totalRUsForSubscription / 730)
        Write-Host "Average consumption for subscription (RUs/hour): $averageRUsPerHour"

        # Remove existing items for "cosmosdbs" before appending
        $allSubscriptionsResults = $allSubscriptionsResults | Where-Object { $_.PlanName -ne "cosmosdbs" -or $_.SubscriptionID -ne $sub.Id }

        # Compile the subscription results
        $subscriptionResult = [PSCustomObject]@{
            SubscriptionID = $sub.Id
            SubscriptionName = $sub.Name
            ResourcesCount = $cosmosDBAccountsCount
            BillableUnits = $averageRUsPerHour
            PlanName = "cosmosdbs"
            EnvironmentType = $environmentType
        }

        # Add this subscription's results to the list
        $allSubscriptionsResults += $subscriptionResult
    }

    # Calculate metrics for Malware Scanning extension for Storage Accounts

    foreach ($sub in $subscriptions) {
        Write-Host "Processing Subscription: $($sub.Name) - $($sub.Id) for Malware Scanning"
        $storageAccountsUri = "/subscriptions/$($sub.Id)/providers/Microsoft.Storage/storageAccounts?api-version=2021-04-01"

        $response = Invoke-AzRestMethod -Method GET -Path $storageAccountsUri -ErrorAction Stop

        $StorageAccounts = $response.Content | ConvertFrom-Json | Select-Object -ExpandProperty value

        if (-not $StorageAccounts) {
            Write-Host "No Storage Accounts found in Subscription: $($sub.Name)"
            continue
        }
     
        $threadSafeDict = [System.Collections.Concurrent.ConcurrentDictionary[string, [Int64]]]::New()

        $storageAccountsCount = ($StorageAccounts | Measure-Object).Count
        Write-Host "Estimating Ingress metric for Malware scanning extension for $($storageAccountsCount) accounts in $($sub.Name)"

        $now = Get-Date
        $lastMonth = $now.AddMonths(-1)

        $StorageAccounts | ForEach-Object -ThrottleLimit 15 -Parallel {
            Write-Host "Processing Storage Account: $($_.id)"
            $totalIngressPerSA = 0
            $now = $USING:now
            $lastMonth = $USING:lastMonth
            $dict = $USING:threadSafeDict
            $body = "{
                'requests':[{
                    'httpMethod':'GET',
                    'relativeUrl': '$($_.id)/blobServices/default/providers/microsoft.Insights/metrics?timespan=$($lastMonth.ToString('u'))/$($now.ToString('u'))&interval=FULL&metricnames=Ingress&aggregation=total&metricNamespace=microsoft.storage%2Fstorageaccounts%2Fblobservices&validatedimensions=false&api-version=2019-07-01'
                }]
            }"
            $resp = Invoke-AzRestMethod -Method POST -Path '/batch?api-version=2015-11-01' -Payload $body
            $totalIngressPerSA += (($resp.Content | ConvertFrom-Json).responses.content.value.timeseries.data | Measure-Object -Property 'total' -Sum).Sum
            $null = $dict.TryAdd($_.Id, $totalIngressPerSA)
        }

        $totalIngressPerSA = $threadSafeDict.Values | Measure-Object -Sum | Select-Object -ExpandProperty Sum
        $totalIngressPerSA_GB = $totalIngressPerSA / 1GB

        $subscriptionResult = [PSCustomObject]@{
            SubscriptionID = $sub.Id
            SubscriptionName = $sub.Name
            ResourcesCount = $storageAccountsCount
            BillableUnits = $totalIngressPerSA_GB
            PlanName = "onuploadmalwarescanning"
            EnvironmentType = $environmentType
        }

        $allSubscriptionsResults += $subscriptionResult
    }

    # Calculate metrics for Defender for AI
    foreach ($sub in $subscriptions) {
        Write-Host "Processing Subscription: $($sub.Name) - $($sub.Id) for Defender for AI"
        $openAiUri = "/subscriptions/$($sub.Id)/providers/Microsoft.CognitiveServices/accounts?api-version=2023-05-01"

        $response = Invoke-AzRestMethod -Method GET -Path $openAiUri -ErrorAction Stop

        $openAiResources = ($response.Content | ConvertFrom-Json).value | Where-Object {
            $_.kind -in @("OpenAI", "AIServices")
        }

        if (-not $openAiResources) {
            Write-Host "No Azure OpenAI resources found in Subscription: $($sub.Name)"
            continue
        }

        $threadSafeDict = [System.Collections.Concurrent.ConcurrentDictionary[string, [Int64]]]::New()

        $openAiResourcesCount = ($openAiResources | Measure-Object).Count
        Write-Host "Estimating token usage for $($openAiResourcesCount) Azure OpenAI resources in $($sub.Name)"

        $now = Get-Date
        $lastMonth = $now.AddMonths(-1)

        $openAiResources | ForEach-Object -ThrottleLimit 15 -Parallel {
            Write-Host "Processing OpenAI Resource: $($_.id)"
            $totalTokens = 0
            $now = $USING:now
            $lastMonth = $USING:lastMonth
            $dict = $USING:threadSafeDict
            $body = "{
                'requests':[{
                    'httpMethod':'GET',
                    'relativeUrl': '$($_.id)/providers/microsoft.Insights/metrics?timespan=$($lastMonth.ToString('u'))/$($now.ToString('u'))&interval=FULL&metricnames=TokenTransaction&aggregation=total&metricNamespace=microsoft.cognitiveservices%2Faccounts&validatedimensions=false&api-version=2019-07-01'
                }]
            }"
            $resp = Invoke-AzRestMethod -Method POST -Path '/batch?api-version=2015-11-01' -Payload $body
            $totalTokens += (($resp.Content | ConvertFrom-Json).responses.content.value.timeseries.data | Measure-Object -Property 'total' -Sum).Sum
            $null = $dict.TryAdd($_.Id, $totalTokens)
        }

        $tokens = $threadSafeDict.Values | Measure-Object -Sum | Select-Object -ExpandProperty Sum

        # Remove existing items for "ai" before appending
        $allSubscriptionsResults = $allSubscriptionsResults | Where-Object { $_.PlanName -ne "ai" -or $_.SubscriptionID -ne $sub.Id }

        # Compile the subscription results
        $subscriptionResult = [PSCustomObject]@{
            SubscriptionID = $sub.Id
            SubscriptionName = $sub.Name
            ResourcesCount = $openAiResourcesCount
            BillableUnits = $tokens
            PlanName = "ai"
            EnvironmentType = $environmentType
        }

        # Add this subscription's results to the list
        $allSubscriptionsResults += $subscriptionResult
    }

    # Calculate metrics for Serverless extension (Web Apps and Function Apps)
    foreach ($sub in $subscriptions) {
        Write-Host "Processing Subscription: $($sub.Name) - $($sub.Id) for Serverless (Web Apps & Function Apps)"
        $webAppsUri = "/subscriptions/$($sub.Id)/providers/Microsoft.Web/sites?api-version=2022-09-01"

        try {
            $response = Invoke-AzRestMethod -Method GET -Path $webAppsUri -ErrorAction Stop
            $webSites = ($response.Content | ConvertFrom-Json).value

            $serverlessCount = 0
            if ($webSites) {
                $serverlessCount = ($webSites | Measure-Object).Count
            }

            Write-Host "Found $serverlessCount Web Apps and Function Apps in $($sub.Name)"

            # Remove existing items for "serverless" before appending
            $allSubscriptionsResults = $allSubscriptionsResults | Where-Object { $_.PlanName -ne "serverless" -or $_.SubscriptionID -ne $sub.Id }

            # Compile the subscription results
            $subscriptionResult = [PSCustomObject]@{
                SubscriptionID = $sub.Id
                SubscriptionName = $sub.Name
                ResourcesCount = $serverlessCount
                BillableUnits = 730
                PlanName = "serverless"
                EnvironmentType = $environmentType
            }

            # Add this subscription's results to the list
            $allSubscriptionsResults += $subscriptionResult
        } catch {
            Write-Error "Failed to retrieve Web Apps/Function Apps in Subscription: $($sub.Name). Error: $_"
            continue
        }
    }
}

$outputPath = "AzureMDCResourcesEstimation_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$allSubscriptionsResults | Export-Csv -Path $outputPath -NoTypeInformation -Force
Write-Host "Plan recommendations for all subscriptions exported to $outputPath successfully."