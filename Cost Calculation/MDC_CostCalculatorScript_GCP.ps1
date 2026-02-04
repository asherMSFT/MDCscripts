# Ensure the required GCP PowerShell module is installed
$requiredModule = "GoogleCloud"
if (-not (Get-Module -ListAvailable -Name $requiredModule)) {
    Write-Host "$requiredModule is not installed. Installing..."
    try {
        Install-Module -Name $requiredModule -Scope CurrentUser -Force -ErrorAction Stop
        Write-Host "$requiredModule installed successfully."
    } catch {
        Write-Error "Failed to install $requiredModule. Please ensure you have the required permissions and internet access."
        exit
    }
} else {
    Write-Host "$requiredModule is already installed."
}

# Import the module
Import-Module $requiredModule

# Authenticate with GCP
Write-Host "Authenticating with GCP..."
gcloud auth login

# Get the list of available projects
$projects = gcloud projects list --format="value(projectId)"
if (-not $projects) {
    Write-Error "No GCP projects found. Please ensure you have access to at least one project."
    exit
}

# Display available projects
Write-Host "Available projects:"
$projects | ForEach-Object { Write-Host "- $_" }

# Prompt the user to select a project or run for all
$selectedOption = Read-Host "Enter 'all' to run for all projects or specify a single project ID"

if ($selectedOption -eq "all") {
    $projectsToProcess = $projects
} elseif ($projects -contains $selectedOption) {
    $projectsToProcess = @($selectedOption)
} else {
    Write-Error "Invalid input. Please run the script again with a valid option."
    exit
}

# Initialize result collection
$allResults = @()

foreach ($selectedProject in $projectsToProcess) {
    Write-Host "Processing project: $selectedProject"

    # Set the selected project
    gcloud config set project $selectedProject

    # Initialize counts
    $totalVMInstances = 0
    $totalSQLInstances = 0
    $totalGKEClusters = 0
    $totalCores = 0
    $totalBuckets = 0

    # Count VM instances
    Write-Host "Counting VM instances..."
    $vmInstances = gcloud -q compute instances list --format="value(name)"
    $totalVMInstances = $vmInstances.Count
    Write-Host "Found $totalVMInstances VM instances."

    # Count SQL database instances
    Write-Host "Counting SQL database instances..."
    $sqlInstances = gcloud -q sql instances list --format="value(name)"
    $totalSQLInstances = $sqlInstances.Count
    Write-Host "Found $totalSQLInstances SQL database instances."

    # Count GKE clusters and cores
    Write-Host "Counting GKE clusters..."
    $allClustersJson = gcloud -q container clusters list --format="json" | ConvertFrom-Json
    $totalGKEClusters = ($allClustersJson | Measure-Object).Count
    Write-Host "Found $totalGKEClusters GKE clusters."

    if ($totalGKEClusters -gt 0) {
        # Get all machine types (used for mapping cores)
        $machineTypes = gcloud compute machine-types list --format="json" | ConvertFrom-Json

        foreach ($cluster in $allClustersJson) {
            $clusterName = $cluster.name
            $clusterLocation = $cluster.location
            $isRegional = $clusterLocation -eq $cluster.location

            $locationFlag = $isRegional ? "--region" : "--zone"
            $clusterDetails = gcloud container clusters describe $clusterName $locationFlag $clusterLocation --format="json" | ConvertFrom-Json

            foreach ($nodePool in $clusterDetails.nodePools) {
                $instanceGroupUrls = $nodePool.instanceGroupUrls

                foreach ($instanceGroupUrl in $instanceGroupUrls) {
                    Write-Host "Processing instance group manager: $instanceGroupUrl"
                    $instanceGroupManager = gcloud compute instance-groups managed describe $instanceGroupUrl $locationFlag $clusterLocation --format="json" | ConvertFrom-Json
                    if (-not $instanceGroupManager) {
                        Write-Host "Could not get instance group manager $instanceGroupUrl. Skipping..."
                        continue
                    }

                    $instanceTemplate = gcloud compute instance-templates describe $instanceGroupManager.instanceTemplate --format="json" | ConvertFrom-Json
                    $machineType = $instanceTemplate.properties.machineType
                    $machineTypeInfo = $machineTypes | Where-Object { $_.name -eq $machineType } | Select-Object -First 1

                    if ($machineTypeInfo) {
                        $coresPerInstance = $machineTypeInfo.guestCpus
                        $instanceGroupName = ($instanceGroupManager.instanceGroup -split "/")[-1]
                        $startTime = (Get-Date).AddMonths(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")
                        $endTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                        $metricFilter = 'metric.type="compute.googleapis.com/instance_group/size" AND resource.labels.instance_group_name="' + $instanceGroupName + '"'
                        $accessToken = gcloud auth print-access-token
                        $url = "https://monitoring.googleapis.com/v3/projects/$selectedProject/timeSeries?filter=$metricFilter&interval.startTime=$startTime&interval.endTime=$endTime&aggregation.alignmentPeriod=3600s&aggregation.perSeriesAligner=ALIGN_MEAN"
                        $headers = @{ "Authorization" = "Bearer $accessToken" }

                        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
                        $averageSize = ($response.timeSeries.points.value.doubleValue | Measure-Object -Average).Average

                        if (-not $averageSize -or $averageSize -eq 0) {
                            Write-Host "No average size data found. Falling back to current size."
                            $instanceGroup = gcloud compute instance-groups describe $instanceGroupManager.instanceGroup $locationFlag $clusterLocation --format="json" | ConvertFrom-Json
                            $instanceGroupSize = $instanceGroup.size
                        } else {
                            $instanceGroupSize = [math]::Round($averageSize)
                        }

                        $instanceGroupCores = $coresPerInstance * $instanceGroupSize
                        $totalCores += $instanceGroupCores

                        Write-Host "Found $instanceGroupSize instances with $coresPerInstance cores in $instanceGroupUrl"
                    } else {
                        Write-Host "Machine type $machineType not found in pre-fetched list."
                    }
                }
            }
        }
    } else {
        Write-Host "No GKE clusters found in the project"
    }

    # Count storage buckets
    Write-Host "Counting storage buckets..."
    $buckets = gcloud -q storage buckets list --format="value(name)"
    $totalBuckets = $buckets.Count
    Write-Host "Found $totalBuckets storage buckets."

    # Create result object
    $environmentType = "GCP"
    $projectResult = @()

    $totalDcspmResources = $totalVMInstances + $totalSQLInstances + $totalBuckets

    $projectResult += [PSCustomObject]@{
        ProjectId = $selectedProject
        EnvironmentName = $null
        ResourcesCount = $totalDcspmResources
        BillableUnits = 730 # Assuming 730 hours in a month
        PlanName = "cloudposture"
        EnvironmentType = $environmentType
    }

    $projectResult += [PSCustomObject]@{
        ProjectId = $selectedProject
        EnvironmentName = $null
        ResourcesCount = $totalVMInstances
        BillableUnits = 730 # Assuming 730 hours in a month
        PlanName = "virtualmachines"
        EnvironmentType = $environmentType
    }

    $projectResult += [PSCustomObject]@{
        ProjectId = $selectedProject
        EnvironmentName = $null
        ResourcesCount = $totalSQLInstances
        BillableUnits = 730 # Assuming 730 hours in a month
        PlanName = "sqlservers"
        EnvironmentType = $environmentType
    }

    $projectResult += [PSCustomObject]@{
        ProjectId = $selectedProject
        EnvironmentName = $null
        ResourcesCount = $totalGKEClusters
        BillableUnits = $totalCores
        PlanName = "containers"
        EnvironmentType = $environmentType
    }

    $allResults += $projectResult
}

# Export to CSV
$outputFile = "GCP_Resource_Summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$allResults | Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "Results exported to $outputFile"