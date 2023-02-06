#!/bin/bash 



myscript=$0
mydirname=`dirname ${myscript}`
if [[ ${mydirname} == "." ]];
    then
     mydirname=`pwd`
fi

cd $mydirname

install_packages() {
  echo "Installing python3, jq and pip packages"
  apt-get update
  apt-get install jq -y 
  apt-get install python3 -y 
  apt-get install python3-pip -y 
  pip3 install --no-cache-dir awscli
  pip install psycopg2-binary 
  pip install boto3 

}

get_env() {

env="$1"


  if [[ -z $env ]]; then

      echo ""
      echo "Please provide env Parameter"
      exit 0
  fi


aws_account_id=$(aws sts get-caller-identity | jq ".Account" | cut -f 2 -d '"')
if [[ -z $aws_account_id ]]; then

    echo "Unable to fetch aws_account_id"
    exit 1
  else
    echo "Successfully Fetched aws_account_id"

  fi
sleep 4

## EKS cluster name 
my_cluster=$(echo "tmp-eks-$env") 
aws_region="us-east-1"


tem_sa_role_name=$(echo "tmp-eks-apps-service-role-$env")

ecr_images=$(echo 602401143452.dkr.ecr.$aws_region.amazonaws.com/amazon/aws-load-balancer-controller:v2.4.2)
path=$(echo "../one-time-apply-yamls")

AWSLoadBalancerControllerIAMPolicy=$(echo "eks-load-balancer-controller-policy-tmp-$env")
load_balancer_role_trust_policy=$(echo "load-balancer-role-trust-policy.json")
fluent_role_trust_policy=$(echo "fluent-role-trust-policy.json")
tem_role_trust_policy=$(echo "tmp-role-trust-policy.json")
AmazonEKSLoadBalancerControllerRole="eks-load-balancer-controller-role-tmp-$env"
fluentControllerRole="fluent-role-$env"
ks8_sa=$(echo "aws-load-balancer-controller-service-account.yaml")
ks8_sa2=$(echo "fluent-bit-service-account.yaml")
#alb_controller_version="https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.4.2/v2_4_2_full.yaml"
alb_controller_file_name=$(echo "aws-load-balancer-controller.yaml")

tags=$(echo "[{\"Key\":\"environment\",\"Value\":\"$env\"},{\"Key\":\"application\",\"Value\":\"tmp\"},{\"Key\":\"creator\",\"Value\":\"aws-cli\"}]")

}


# download iam policy
iam_policy() {

curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.2/docs/install/iam_policy.json

sleep 3
}

iam_create_policy() {

aws iam create-policy \
    --policy-name $AWSLoadBalancerControllerIAMPolicy \
    --tags $tags \
    --policy-document file://iam_policy.json
sleep 5
}

get_oid() {
oid_id=$(aws eks describe-cluster --name $my_cluster --query "cluster.identity.oidc.issuer" --region $aws_region --output text | cut -f 5 -d '/')

  if [[ -z $oid_id ]]; then

    echo "Unable to fetch oid"
    exit 1
  else

    echo "Successfully Fetched oid"

  fi

}

create_trust_policy() {

cat <<EOF > $load_balancer_role_trust_policy
{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Federated": "arn:aws:iam::$aws_account_id:oidc-provider/oidc.eks.$aws_region.amazonaws.com/id/$oid_id"
                },
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {
                    "StringEquals": {
                        "oidc.eks.$aws_region.amazonaws.com/id/$oid_id:aud": "sts.amazonaws.com",
                        "oidc.eks.$aws_region.amazonaws.com/id/$oid_id:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
                    }
                }
            }
        ]
}
EOF
}


iam_create_role() {

aws iam create-role \
  --role-name $AmazonEKSLoadBalancerControllerRole \
  --tags $tags \
  --assume-role-policy-document file://$load_balancer_role_trust_policy
sleep 10
}

iam_attach_role_policy() {

sleep 5

aws iam attach-role-policy \
  --policy-arn arn:aws:iam::$aws_account_id:policy/$AWSLoadBalancerControllerIAMPolicy \
  --role-name $AmazonEKSLoadBalancerControllerRole

}


ks8_service_account() {

cat <<EOF > $ks8_sa

apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::$aws_account_id:role/$AmazonEKSLoadBalancerControllerRole

EOF

sleep 2
kubectl apply -f "$ks8_sa"
#downlaod cert
sleep 5
kubectl apply \
    --validate=false \
    -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml

}

ks8_apply() {

#curl -Lo $alb_controller_file_name https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.4.2/v2_4_2_full.yaml

	echo "function ks8_apply 1"

    sed -i -e  s/your-cluster-name/$my_cluster/ $path/aws-load-balancer-controller.yaml
    sed -i -e s#amazon/aws-alb-ingress-controller:v2.4.2#$ecr_images# $path/aws-load-balancer-controller.yaml


        sleep 15
	
        kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

        sleep 30

        kubectl apply -f $path/aws-load-balancer-controller.yaml

        echo "Waiting to get pod status..."

        sleep 60
        #status

        get_status=$(kubectl get pods -n kube-system | grep -i 'aws-load-balancer-controller' | awk '{print $3}' | head -1)

            if [[ $get_status == 'Running' ]]; then

              echo "PASS: aws-load-balancer-controller is deployed successfully"
            else
              echo "FAIL: check aws-load-balancer-controller logs"
            fi
}

### Fluent Bit
##########################################

create_fluent_trust_policy() {

cat <<EOF > $fluent_role_trust_policy
{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Federated": "arn:aws:iam::$aws_account_id:oidc-provider/oidc.eks.$aws_region.amazonaws.com/id/$oid_id"
                },
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {
                    "StringEquals": {
                        "oidc.eks.$aws_region.amazonaws.com/id/$oid_id:aud": "sts.amazonaws.com",
                        "oidc.eks.$aws_region.amazonaws.com/id/$oid_id:sub": "system:serviceaccount:amazon-cloudwatch:fluent-bit"
                    }
                }
            }
        ]
}
EOF
}

iam_create_role_fluent() {

sleep 5

aws iam create-role \
  --role-name $fluentControllerRole \
  --tags $tags \
  --assume-role-policy-document file://$fluent_role_trust_policy
sleep 10
}

iam_attach_CloudWatchAgentServerPolicy_to_role() {
  aws iam attach-role-policy \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
    --role-name $fluentControllerRole

}


ks8_service_account_fluent() {

cat <<EOF > $ks8_sa2

apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: amazon-cloudwatch
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::$aws_account_id:role/$fluentControllerRole

EOF

sleep 3

kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml

sleep 5

kubectl apply -f "$ks8_sa2"

}



apply_fluent_bit() {


ClusterName=$my_cluster
RegionName=$aws_region
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
kubectl create configmap fluent-bit-cluster-info \
--from-literal=cluster.name=${ClusterName} \
--from-literal=http.server=${FluentBitHttpServer} \
--from-literal=http.port=${FluentBitHttpPort} \
--from-literal=read.head=${FluentBitReadFromHead} \
--from-literal=read.tail=${FluentBitReadFromTail} \
--from-literal=logs.region=${RegionName} -n amazon-cloudwatch

sleep 3

#eksctl create iamserviceaccount --region us-east-1 --name fluent-bit --namespace amazon-cloudwatch --cluster esk-tmp-uat --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy --override-existing-serviceaccounts --approve

kubectl apply -f $path/fluent-bit.yaml
echo "Waiting to get pod status..."

sleep 60
#status

get_status_f=$(kubectl get pods -n amazon-cloudwatch | grep -i 'fluent' | awk '{print $3}' | head -1)

    if [[ $get_status_f == 'Running' ]]; then

      echo "PASS: fluent-bit deployed successfully"
    else
      echo "FAIL: check fluent-bit logs"
    fi

}



#Execution Flow
#install_packages
get_env $1

#aws-load-balancer-controller
get_oid
iam_policy
iam_create_policy
create_trust_policy
iam_create_role
iam_attach_role_policy
ks8_service_account
ks8_apply


## Execution flow fluent-bit
create_fluent_trust_policy
iam_create_role_fluent
iam_attach_CloudWatchAgentServerPolicy_to_role
ks8_service_account_fluent
apply_fluent_bit


