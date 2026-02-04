# Ensure the required AWS PowerShell module is installed
$requiredModule = "AWSPowerShell"
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

# Parse AWS profiles from the AWS credentials file (~/.aws/credentials)
$credentialsFile = Join-Path -Path $HOME -ChildPath ".aws\credentials"
if (-not (Test-Path $credentialsFile)) {
    Write-Error "AWS credentials file not found at $credentialsFile. Please ensure your AWS CLI is configured."
    exit
}

# Extract profiles
$profiles = Get-Content $credentialsFile | Where-Object { $_ -match "^\[(.*)\]$" } | ForEach-Object { $_ -replace "^\[(.*)\]$", '$1' }
if (-not $profiles) {
    Write-Error "No profiles found in the AWS credentials file. Please ensure you have set up profiles using 'aws configure'."
    exit
}

# Display available profiles
Write-Host "Available profiles:"
$profiles | ForEach-Object { Write-Host "- $_" }

# Prompt the user to select a profile
$selectedProfile = Read-Host "Enter the name of the profile you want to use"

if (-not ($profiles -contains $selectedProfile)) {
    Write-Error "Invalid profile name. Please run the script again with a valid profile."
    exit
}

# Set the selected profile
Set-AWSCredential -ProfileName $selectedProfile

# Initialize counts
$totalEC2Instances = 0
$totalSQLInstances = 0
$totalEKSClusters = 0
$totalCores = 0
$totalS3Buckets = 0
$totalLambdaFunctions = 0

$defaultRegion = "us-east-1"

# Get all AWS regions
$regions = Get-EC2Region -Region $defaultRegion | Select-Object -ExpandProperty RegionName

foreach ($region in $regions) {
    Write-Host "Processing region: $region"

    # Set the current region
    Set-DefaultAWSRegion -Region $region

    # Count EC2 instances in the region
    Write-Host "Counting EC2 instances in region: $region"
    $ec2Instances = (Get-EC2Instance).Instances
    $regionEC2InstanceCount = $ec2Instances.Count
    Write-Host "Found $regionEC2InstanceCount EC2 instances in region: $region"
    $totalEC2Instances += $regionEC2InstanceCount

    # Count RDS SQL database instances in the region
    Write-Host "Counting RDS SQL database instances in region: $region"
    $sqlInstances = Get-RDSDBInstance
    $regionSQLInstanceCount = $sqlInstances.Count
    Write-Host "Found $regionSQLInstanceCount RDS SQL database instances in region: $region"
    $totalSQLInstances += $regionSQLInstanceCount

    # Count EKS clusters in the region
    Write-Host "Counting EKS clusters in region: $region"
    $eksClusters = Get-EKSClusterList
    $regionEKSClusterCount = $eksClusters.Count
    Write-Host "Found $regionEKSClusterCount EKS clusters in region: $region"
    $totalEKSClusters += $regionEKSClusterCount

    # Count Lambda functions in the region (for Serverless extension)
    Write-Host "Counting Lambda functions in region: $region"
    try {
        $lambdaFunctions = Get-LMFunctionList
        $regionLambdaCount = $lambdaFunctions.Count
        Write-Host "Found $regionLambdaCount Lambda functions in region: $region"
        $totalLambdaFunctions += $regionLambdaCount
    } catch {
        Write-Host "Error counting Lambda functions in region: $region - $_"
    }
    
    # Count total nodes and cores across EKS clusters in the region
    Write-Host "Counting EKS nodes and cores in region: $region"
    foreach ($clusterName in $eksClusters) {
        Write-Host "Processing EKS cluster: $clusterName"
        Write-Host "Retrieving node groups for EKS cluster: $clusterName"
        $nodeGroups = Get-EKSNodegroupList -ClusterName $clusterName
        Write-Host "Found node groups: $($nodeGroups -join ', ') for EKS cluster: $clusterName"
        foreach ($nodeGroup in $nodeGroups) {
            Write-Host "Processing node group: $nodeGroup in cluster: $clusterName"
            $nodeGroupInfo = Get-EKSNodegroup -ClusterName $clusterName -NodegroupName $nodeGroup
            $nodeCount = $nodeGroupInfo.ScalingConfig.DesiredSize
            Write-Host "Found $nodeCount nodes in node group: $nodeGroup of cluster: $clusterName"

            # Count cores in the node group
            $autoScalingGroupNames = $nodeGroupInfo.Resources.AutoScalingGroups.Name
            foreach ($autoScalingGroupName in $autoScalingGroupNames) {
                Write-Host "Processing Auto Scaling Group: $autoScalingGroupName"
                $autoScalingGroup = Get-ASAutoScalingGroup | Where-Object { $_.AutoScalingGroupName -eq $autoScalingGroupName }
                $currentInstanceCount = $autoScalingGroup.Instances.Count

                # Get the average number of instances in the auto scaling group over the past month
                $endTime = (Get-Date)
                $startTime = $endTime.AddMonths(-1)
                $metricData = Get-CWMetricStatistics -Namespace "AWS/AutoScaling" -MetricName "GroupTotalInstances" -Dimensions @{ Name="AutoScalingGroupName"; Value=$autoScalingGroupName } -StartTime $startTime -EndTime $endTime -Period 86400 -Statistics "Average"
                $averageInstanceCount = ($metricData.Datapoints | Measure-Object -Property Average -Average).Average

                foreach ($instance in $autoScalingGroup.Instances) {
                    $instanceType = $instance.InstanceType
                    Write-Host "Processing instance type: $instanceType in Auto Scaling Group: $autoScalingGroupName"
                    $coresInfo = Get-EC2InstanceType | Where-Object { $_.InstanceType -eq $instanceType }
                    $numOfCores = $coresInfo.VCpuInfo.DefaultVCpus

                    if ($averageInstanceCount -ne $null -and $averageInstanceCount -ne 0) {
                        # Adjust the number of cores by the factor of average / current number of instances
                        $adjustedCores = $numOfCores * ($averageInstanceCount / $currentInstanceCount)
                        $totalCores += $adjustedCores
                        Write-Host "$($adjustedCores) adjusted vCPUs for instance type: $instanceType"
                    } else {
                        $totalCores += $numOfCores
                        Write-Host "$($numOfCores) vCPUs for instance type: $instanceType"
                    }
                }
            }
        }
    }
}

# Count S3 buckets
Write-Host "Counting S3 buckets"
$s3Buckets = Get-S3Bucket
$totalS3Buckets = $s3Buckets.Count
Write-Host "Found $totalS3Buckets S3 buckets"

# Display the results
Write-Host "Summary:"
Write-Host "Profile: $selectedProfile"
Write-Host "Total EC2 Instances: $totalEC2Instances"
Write-Host "Total SQL Database Instances: $totalSQLInstances"
Write-Host "Total EKS Clusters: $totalEKSClusters"
Write-Host "Total cores: $totalCores"
Write-Host "Total S3 Buckets: $totalS3Buckets"
Write-Host "Total Lambda Functions: $totalLambdaFunctions"

# Create a custom object to store the results
$environmentType = "AWS"
$accountResult = @()
# Fetch Account ID from AWS API
$accountId = (Get-STSCallerIdentity -Region $defaultRegion ).Account

$totalDcspmResources = $totalEC2Instances + $totalSQLInstances + $totalS3Buckets

$accountResult += [PSCustomObject]@{
    AccountId = $accountId
    EnvironmentName = $null
    ResourcesCount = $totalDcspmResources
    BillableUnits = 730 # Assuming 730 hours in a month
    PlanName = "cloudposture"
    EnvironmentType = $environmentType
}

$accountResult += [PSCustomObject]@{
    AccountId = $accountId
    EnvironmentName = $null
    ResourcesCount = $totalEC2Instances
    BillableUnits = 730 # Assuming 730 hours in a month
    PlanName = "virtualmachines"
    EnvironmentType = $environmentType
}

$accountResult += [PSCustomObject]@{
    AccountId = $accountId
    EnvironmentName = $null
    ResourcesCount = $totalSQLInstances
    BillableUnits = 730 # Assuming 730 hours in a month
    PlanName = "sqlservers"
    EnvironmentType = $environmentType
}

$accountResult += [PSCustomObject]@{
    AccountId = $accountId
    EnvironmentName = $null
    ResourcesCount = $totalEKSClusters
    BillableUnits = $totalCores
    PlanName = "containers"
    EnvironmentType = $environmentType
}

$accountResult += [PSCustomObject]@{
    AccountId = $accountId
    EnvironmentName = $null
    ResourcesCount = $totalLambdaFunctions
    BillableUnits = 730 # Assuming 730 hours in a month
    PlanName = "serverless"
    EnvironmentType = $environmentType
}

# Export the results to a CSV file
$outputFile = "AWS_Resource_Summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$accountResult | Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "Results exported to $outputFile"