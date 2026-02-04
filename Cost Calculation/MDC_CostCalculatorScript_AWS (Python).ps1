import boto3
import subprocess
import datetime
import csv
import asyncio
import logging
import json
import os
import time

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

SSO_PROFILE = None  # Will be set by user selection
CONCURRENCY_LIMIT = 10

def get_sso_url():
    result = subprocess.run(
        ["aws", "configure", "get", "sso_start_url", "--profile", SSO_PROFILE],
        capture_output=True, text=True
    )
    return result.stdout.strip()

def get_sso_region():
    result = subprocess.run(
        ["aws", "configure", "get", "region", "--profile", SSO_PROFILE],
        capture_output=True, text=True
    )
    return result.stdout.strip() or "us-east-2"  # Default to us-east-2 if not set

def ensure_sso_login():
    logging.info("Checking current SSO session with sts get-caller-identity...")
    try:
        result = subprocess.run(["aws", "sts", "get-caller-identity", "--profile", SSO_PROFILE], capture_output=True, text=True)
        if result.returncode != 0 or 'error' in result.stderr.lower():
            logging.info("SSO session invalid or expired. Running aws sso login...")
            subprocess.run(["aws", "sso", "login", "--profile", SSO_PROFILE], check=True)
    except Exception as e:
        logging.error(f"Failed to verify or refresh SSO session: {e}")
        raise

def list_sso_accounts():
    try:
        sso_region = get_sso_region()
        result = subprocess.run([
            "aws", "organizations", "list-accounts",
            "--region", sso_region,
            "--profile", SSO_PROFILE
        ], capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        return [
            {"accountId": acct["Id"], "accountName": acct["Name"]}
            for acct in data.get("Accounts", [])
            if acct["Status"] == "ACTIVE"
        ]
    except subprocess.CalledProcessError as e:
        logging.error(f"Failed to list SSO accounts: {e.stderr}")
        return []

def get_sso_cached_token():
    logging.info("Attempting to load SSO access token from cache...")
    cache_dir = os.path.expanduser("~/.aws/sso/cache")
    if not os.path.isdir(cache_dir):
        logging.warning("SSO cache directory not found. Attempting to login...")
        subprocess.run(["aws", "sso", "login", "--profile", SSO_PROFILE], check=True)

    def find_token():
        best_match = None
        best_mtime = 0
        fallback_token = None
        fallback_mtime = 0
        for filename in os.listdir(cache_dir):
            path = os.path.join(cache_dir, filename)
            try:
                with open(path, "r") as f:
                    data = json.load(f)
                    logging.debug(f"Token file {filename} => startUrl: {data.get('startUrl')}")
                    if "accessToken" in data:
                        mtime = os.path.getmtime(path)
                        if data.get("startUrl") == get_sso_url():
                            if mtime > best_mtime:
                                best_match = data["accessToken"]
                                best_mtime = mtime
                        elif fallback_token is None or mtime > fallback_mtime:
                            fallback_token = data["accessToken"]
                            fallback_mtime = mtime
            except Exception as e:
                logging.warning(f"Failed to parse cache file {filename}: {e}")
        return best_match or fallback_token

    token = find_token()
    if token:
        logging.info("SSO access token successfully loaded from cache.")
        return token

    logging.info("Access token not found or expired. Running aws sso login...")
    subprocess.run(["aws", "sso", "login", "--profile", SSO_PROFILE], check=True)

    for i in range(6):  # retry for ~30 seconds
        logging.info("Waiting for SSO login to complete...")
        time.sleep(5)
        token = find_token()
        if token:
            logging.info("SSO access token loaded successfully after retry.")
            return token

    logging.error("SSO access token not found in cache after login. Aborting.")
    raise RuntimeError("No valid SSO access token found in cache after login attempt. Make sure you finish login in the browser.")

def get_sso_role(account_id):
    result = subprocess.run(
        ["aws", "configure", "get", "sso_role_name", "--profile", SSO_PROFILE],
        capture_output=True, text=True
    )
    return result.stdout.strip()

def assume_role(account_id):
    role_name = get_sso_role(account_id)
    if not role_name:
        logging.warning(f"No suitable role to assume for account {account_id}")
        return None
    try:
        access_token = get_sso_cached_token()
        if not access_token:
            raise ValueError("SSO access token not found or invalid.")

        result = subprocess.run([
            "aws", "sso", "get-role-credentials",
            "--account-id", account_id,
            "--role-name", role_name,
            "--access-token", access_token,
            "--region", get_sso_region()
        ], capture_output=True, text=True, check=True)
        creds = json.loads(result.stdout)['roleCredentials']

        if not all(k in creds for k in ("accessKeyId", "secretAccessKey", "sessionToken")):
            raise ValueError(f"Incomplete credentials received for account {account_id}")

        return boto3.Session(
            aws_access_key_id=creds['accessKeyId'],
            aws_secret_access_key=creds['secretAccessKey'],
            aws_session_token=creds['sessionToken']
        )
    except Exception as e:
        logging.error(f"Error assuming role for account {account_id} with role {role_name}: {e}")
        return None

def get_regions(session):
    try:
        logging.info("Fetching AWS regions using EC2 client...")
        regions = session.client("ec2", region_name=get_sso_region()).describe_regions()["Regions"]
        region_names = [r["RegionName"] for r in regions]
        logging.info(f"Discovered regions: {region_names}")
        return region_names
    except Exception as e:
        logging.error(f"Failed to fetch regions: {e}")
        return []

def retry_task_sync(task_fn, retries=3):
    for attempt in range(retries):
        try:
            return task_fn()
        except Exception as e:
            if attempt == retries - 1:
                logging.error(f"Retry failed after {retries} attempts: {e}")
                raise
            time.sleep(2 ** attempt)

async def retry_task(task, retries=3):
    for attempt in range(retries):
        try:
            return await task
        except Exception as e:
            if attempt == retries - 1:
                logging.error(f"Retry failed after {retries} attempts: {e}")
                raise
            await asyncio.sleep(2 ** attempt)

async def count_resources(session):
    total = {'ec2': 0, 'rds': 0, 's3': 0, 'eks': 0, 'cores': 0, 'lambda': 0}
    instance_type_cache = {}

    def fetch_region(region):
        logging.info(f"🔄 Starting resource fetch for region: {region}")
        try:
            logging.debug(f"Creating session and clients for region {region}")
            regional = boto3.Session(
                aws_access_key_id=session.get_credentials().access_key,
                aws_secret_access_key=session.get_credentials().secret_key,
                aws_session_token=session.get_credentials().token,
                region_name=region
            )
            ec2 = regional.client("ec2")
            rds = regional.client("rds")
            eks = regional.client("eks")
            asg = regional.client("autoscaling")
            cw = regional.client("cloudwatch")
            lmb = regional.client("lambda")

            # EC2
            try:
                reservations = ec2.describe_instances().get('Reservations', [])
                instance_count = sum(len(r['Instances']) for r in reservations)
                total['ec2'] += instance_count
                logging.info(f"Found {instance_count} EC2 instances in {region}")
            except Exception as e:
                logging.warning(f"Failed to fetch EC2 instances in {region}: {str(e)}")

            # RDS
            try:
                dbs = rds.describe_db_instances().get('DBInstances', [])
                total['rds'] += len(dbs)
                logging.info(f"Found {len(dbs)} RDS instances in {region}")
            except Exception as e:
                logging.warning(f"Failed to fetch RDS instances in {region}: {str(e)}")

            # EKS
            try:
                clusters = eks.list_clusters().get("clusters", [])
                total['eks'] += len(clusters)
                logging.info(f"Found {len(clusters)} EKS clusters in {region}")

                for cluster in clusters:
                    logging.debug(f"Processing nodegroups for cluster {cluster}")
                    nodegroups = eks.list_nodegroups(clusterName=cluster).get("nodegroups", [])

                    logging.info(f"Found node groups: {', '.join(nodegroups)} for EKS cluster {cluster}")

                    for ng in nodegroups:
                        logging.debug(f"Processing node group: {ng} in cluster: {cluster}")
                        ng_info = eks.describe_nodegroup(clusterName=cluster, nodegroupName=ng)['nodegroup']

                        desired = ng_info['scalingConfig'].get('desiredSize', 0)
                        logging.info(f"Desired size for nodegroup {ng}: {desired}")

                        asg_names = [asg_ref['name'] for asg_ref in ng_info['resources'].get('autoScalingGroups', [])]
                        for asg_name in asg_names:
                            logging.debug(f"Processing Auto Scaling Group: {asg_name}")
                            asg_info = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
                            groups = asg_info.get('AutoScalingGroups', [])
                            if not groups:
                                continue
                            group = groups[0]
                            current_instance_count = len(group.get('Instances', []))

                            # Average instance count over past month
                            end_time = datetime.datetime.now(datetime.UTC)
                            start_time = end_time - datetime.timedelta(days=30)
                            metric_data = cw.get_metric_statistics(
                                Namespace="AWS/AutoScaling",
                                MetricName="GroupTotalInstances",
                                Dimensions=[{'Name': 'AutoScalingGroupName', 'Value': asg_name}],
                                StartTime=start_time,
                                EndTime=end_time,
                                Period=86400,  # 1 day
                                Statistics=["Average"]
                            )
                            datapoints = metric_data.get("Datapoints", [])
                            avg_instance_count = (sum(dp["Average"] for dp in datapoints) / len(datapoints)) if datapoints else None

                            # Count cores
                            for inst in group.get('Instances', []):
                                instance_type = inst.get('InstanceType')
                                if not instance_type:
                                    continue

                                if instance_type not in instance_type_cache:
                                    ec2_types = ec2.describe_instance_types(InstanceTypes=[instance_type])
                                    instance_type_cache[instance_type] = ec2_types['InstanceTypes'][0]['VCpuInfo']['DefaultVCpus']
                                num_cores = instance_type_cache[instance_type]

                                if avg_instance_count and avg_instance_count != 0 and current_instance_count > 0:
                                    adjusted_cores = num_cores * (avg_instance_count / current_instance_count)
                                    total['cores'] += adjusted_cores
                                    logging.debug(f"{adjusted_cores} adjusted vCPUs for {instance_type} in {asg_name}")
                                else:
                                    total['cores'] += num_cores
                                    logging.debug(f"{num_cores} vCPUs for {instance_type} in {asg_name}")
            except Exception as e:
                logging.warning(f"Failed to fetch EKS clusters in {region}: {str(e)}")

            # Lambda
            try:
                lambda_functions = lmb.list_functions().get('Functions', [])
                total['lambda'] += len(lambda_functions)
                logging.info(f"Found {len(lambda_functions)} Lambda functions in {region}")
            except Exception as e:
                logging.warning(f"Failed to fetch Lambda functions in {region}: {str(e)}")

        except Exception as e:
            logging.error(f"Failed to process region {region}: {str(e)}")

    regions = get_regions(session)
    tasks = [asyncio.to_thread(fetch_region, r) for r in regions]
    await asyncio.gather(*tasks)

    # S3
    try:
        s3 = session.client("s3")
        total['s3'] += len(s3.list_buckets().get('Buckets', []))
    except:
        logging.warning(f"Failed to fetch S3 buckets")

    return total['ec2'], total['rds'], total['s3'], total['eks'], total['cores'], total['lambda']

async def process_account(account, results):
    acct_id = account['accountId']
    acct_name = account['accountName']
    logging.info(f"Processing account: {acct_id} - {acct_name}")

    start_time = time.time()
    session = await asyncio.to_thread(assume_role, acct_id)
    if not session:
        logging.error(f"❌ Failed to assume session for account {acct_id} ({acct_name}). Skipping.")
        return

    ec2, rds, s3, eks, cores, lmb = await count_resources(session)
    if ec2 + rds + s3 + eks + lmb == 0:
        logging.warning(f"⚠️ No resources found in account {acct_id} ({acct_name}). This may indicate access issues.")

    elapsed = time.time() - start_time
    logging.info(f"✅ Account: {acct_name} ({acct_id}) => EC2: {ec2}, RDS: {rds}, S3: {s3}, EKS: {eks}, Cores: {cores}, Lambda: {lmb} — Time: {elapsed:.2f}s")

    results.extend([
        {"AccountId": acct_id, "EnvironmentName": None, "ResourcesCount": ec2 + rds + s3, "BillableUnits": 730, "PlanName": "cloudposture", "EnvironmentType": "AWS"},
        {"AccountId": acct_id, "EnvironmentName": None, "ResourcesCount": ec2, "BillableUnits": 730, "PlanName": "virtualmachines", "EnvironmentType": "AWS"},
        {"AccountId": acct_id, "EnvironmentName": None, "ResourcesCount": rds, "BillableUnits": 730, "PlanName": "sqlservers", "EnvironmentType": "AWS"},
        {"AccountId": acct_id, "EnvironmentName": None, "ResourcesCount": eks, "BillableUnits": cores, "PlanName": "containers", "EnvironmentType": "AWS"},
        {"AccountId": acct_id, "EnvironmentName": None, "ResourcesCount": lmb, "BillableUnits": 730, "PlanName": "serverless", "EnvironmentType": "AWS"}
    ])

def list_aws_profiles():
    try:
        result = subprocess.run(["aws", "configure", "list-profiles"], capture_output=True, text=True, check=True)
        profiles = result.stdout.strip().split('\n')
        return profiles
    except subprocess.CalledProcessError as e:
        logging.error(f"Failed to list AWS profiles: {e.stderr}")
        return ['default']

def select_profile():
    profiles = list_aws_profiles()
    print("\nAvailable AWS profiles:")
    for idx, profile in enumerate(profiles, 1):
        print(f"{idx}. {profile}")
    
    while True:
        try:
            choice = int(input("\nSelect a profile (enter number): ")) - 1
            if 0 <= choice < len(profiles):
                return profiles[choice]
            print("Invalid selection. Please try again.")
        except ValueError:
            print("Please enter a valid number.")

def select_account_scope():
    print("\nSelect account scope:")
    print("1. Single account (current profile) - Requires SSO login and permission to access EC2, RDS, S3, EKS, Lambda and IAM services")
    print("2. Organization (all accounts) - Requires SSO login to management account. Make sure the role associated with the profile can be assumed in all member accounts and has permissions to access Organizations, EC2, RDS, S3, EKS, Lambda and IAM services")
    
    while True:
        try:
            choice = int(input("\nEnter your choice (1 or 2): "))
            if choice in [1, 2]:
                return choice == 2
            print("Invalid selection. Please try again.")
        except ValueError:
            print("Please enter a valid number.")

async def main():
    # Let user select profile
    global SSO_PROFILE
    SSO_PROFILE = select_profile()
    print(f"\nSelected profile: {SSO_PROFILE}")

    # Let user select account scope
    use_organization = select_account_scope()
    start_global = time.time()
    ensure_sso_login()
    # Initialize accounts list based on user choice
    accounts = []
    if use_organization:
        accounts = list_sso_accounts()
    else:
        # For single account, we need to get the account ID from caller identity
        try:
            result = subprocess.run(
                ["aws", "sts", "get-caller-identity", "--profile", SSO_PROFILE],
                capture_output=True, text=True, check=True
            )
            data = json.loads(result.stdout)
            account_id = data['Account']
            result = subprocess.run(
                ["aws", "iam", "list-account-aliases", "--profile", SSO_PROFILE],
                capture_output=True, text=True
            )
            account_name = json.loads(result.stdout).get('AccountAliases', [account_id])[0]
            accounts = [{"accountId": account_id, "accountName": account_name}]
        except Exception as e:
            logging.error(f"Failed to get account information: {e}")
            return
    if not accounts:
        print("No accounts found. Ensure your SSO session is active and credentials are valid.")
        return

    print(f"\n[INFO] Discovered {len(accounts)} accounts.\n")
    results = []
    semaphore = asyncio.Semaphore(CONCURRENCY_LIMIT)

    async def limited_process(account):
        async with semaphore:
            await process_account(account, results)

    await asyncio.gather(*(limited_process(a) for a in accounts))

    file = f"AWS_Resource_Summary_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    with open(file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["AccountId", "EnvironmentName", "ResourcesCount", "BillableUnits", "PlanName", "EnvironmentType"])
        writer.writeheader()
        writer.writerows(results)

    print(f"Results exported to {file}")
    print("📊 Summary Report")
    print(f"⏱️  Total elapsed time: {time.time() - start_global:.2f} seconds")

if __name__ == "__main__":
    asyncio.run(main())