#!/bin/bash
environment="sandbox"
costCenter="pec"
projectID="pec2"
location="westus2"
subscription="Aquarium"
resourceGroupName1="${projectID}_${location}"
resourceGroupName2="${projectID}_${location}_AKS"
VNetName1="${resourceGroupName1}_VNet"
AksSubName1="AKS"
aksname="${projectID}aks"
acrname="${projectID}${projectID}acr"
kvname="${projectID}${projectID}kv"
aksVMSize="Standard_B2s"
aksNodeCount=3
kubeVersion="1.17.3"
adminUserName="localadmin"
mongodbPassword="p&e@cB(OWslk2187(*&ab"
workspaceName="${projectID}${location}logs"

##############################
#  Basics
##############################
sudo apt update
sudo apt install jq
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az extension add --name aks-preview

az account set --subscription $subscription
az group create --name $resourceGroupName1 --location $location

##############################
#  Service Principal
##############################
if test -f "aksserviceprincipal.json"; then
    echo "Service Principal details found"
else
    echo "Create a service principal for AKS"
    az ad sp create-for-rbac --skip-assignment --name "${aksname}sp" -o json >> aksserviceprincipal.json
fi

spAppId=$(jq -r .appId aksserviceprincipal.json)
spPassword=$(jq -r '.password' aksserviceprincipal.json)
subscriptionId=$(az account show --subscription $subscription --query 'id' -o tsv)
tenantId=$(az account show --query 'tenantId' --output tsv)


scope="/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName1}"
az role assignment create --assignee $spAppId --scope $scope --role Contributor

exit
##############################
#  AKS
##############################
echo "Create AKS Cluster"
az aks create --name $aksname --resource-group $resourceGroupName1 --location $location --node-resource-group $resourceGroupName2 \
--admin-username $adminUserName --generate-ssh-keys --node-count $aksNodeCount --node-vm-size $aksVMSize \
--load-balancer-sku standard --vm-set-type VirtualMachineScaleSets \
--network-policy calico --network-plugin azure --service-principal $spAppId --client-secret $spPassword \
--verbose --tags "Environment=$environment" "CostCenter=$costCenter" "ProjectID=$projectID" \
--kubernetes-version $kubeVersion
    
# az aks nodepool add --resource-group $resourceGroupName1 --cluster-name $aksname  --name "nodepool2" --node-count $aksNodeCount

az aks get-credentials --resource-group $resourceGroupName1 --name $aksname

##############################
#  Log Analytics
##############################
az resource create --resource-type Microsoft.OperationalInsights/workspaces \
 --name $workspaceName \
 --resource-group $resourceGroupName1 \
 --location $location \
 --properties '{}' -o table

workspace=$(az resource show --resource-type Microsoft.OperationalInsights/workspaces --resource-group $resourceGroupName1 --name $workspaceName --query "id" -o tsv)
az aks enable-addons --resource-group $resourceGroupName1 --name $aksname \
--addons monitoring --workspace-resource-id $workspace


##############################
#  Helm 3
##############################
wget https://get.helm.sh/helm-v3.1.2-linux-amd64.tar.gz
tar -zxvf helm-v3.1.2-linux-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin/helm
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
helm repo update

##############################
#  Mongo
##############################
helm install orders-mongo stable/mongodb --set mongodbUsername=orders-user,mongodbPassword=${mongodbPassword},mongodbDatabase=akschallenge
helm uninstall orders-mongo
##############################
#  Ingress
##############################
kubectl create namespace ingress
helm install ingress stable/nginx-ingress --namespace ingress
pubip=$(kubectl get svc -n ingress ingress-nginx-ingress-controller -o jsonpath="{.status.loadBalancer.ingress[*].ip}")
echo "captureorder.${pubip}.nip.io"
echo "frontend.${pubip}.nip.io"

##############################
#  Certificates
##############################
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl apply --validate=false -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.11/deploy/manifests/00-crds.yaml
kubectl create namespace cert-manager
helm install cert-manager --namespace cert-manager jetstack/cert-manager

##############################
#  API
##############################
kubectl create secret generic mongodb --from-literal=mongoHost="orders-mongo-mongodb.default.svc.cluster.local" \
--from-literal=mongoUser="orders-user" --from-literal=mongoPassword="${mongodbPassword}"
kubectl apply -f captureorder-deployment.yaml
kubectl apply -f captureorder-service.yaml
kubectl apply -f captureorder-ingress-tls.yaml
kubectl apply -f captureorder-hpa.yaml

curl -d --insecure '{"EmailAddress": "email@domain.com", "Product": "prod-1", "Total": 100}' -H "Content-Type: application/json" -X POST "https://captureorder.${pubip}.nip.io/v1/order"
curl -X --insecure GET "https://captureorder.${pubip}.nip.io/v1/order" -H  "accept: application/json"


##############################
#  Front End
##############################
kubectl apply -f frontend-deployment.yaml
kubectl apply -f frontend-service.yaml
kubectl apply -f frontend-ingress-tls.yaml

##############################
#  Load Test
##############################
az container create -g $resourceGroupName1 -n loadtest --image azch/loadtest --restart-policy Never -e SERVICE_ENDPOINT=https://captureorder.${pubip}.nip.io
az container logs -g $resourceGroupName1 -n loadtest --follow
az container delete -g $resourceGroupName1 -n loadtest -y

az aks scale --resource-group $resourceGroupName1 --name $aksname --node-count 2

##############################
#  ACR
##############################
az acr create --resource-group $resourceGroupName1 --name $acrname --sku Standard --location $location

git clone https://github.com/Azure/azch-loadtest.git
git clone https://github.com/Azure/azch-frontend.git
git clone https://github.com/Azure/azch-captureorder.git

cd azch-captureorder
az acr build -t "captureorder:{{.Run.ID}}" -r $acrname .
az aks update -n $aksname -g $resourceGroupName1 --attach-acr $acrname

##############################
#  MongoDB replication using a StatefulSet
##############################
helm upgrade orders-mongo stable/mongodb --set replicaSet.enabled=true,mongodbUsername=orders-user,mongodbPassword=${mongodbPassword},mongodbDatabase=akschallenge
kubectl get pods -l app=mongodb -w
kubectl scale statefulset orders-mongo-mongodb-secondary --replicas=2
kubectl get pods -l app=mongodb -w


##############################
#  Key Vault
##############################
az keyvault create --resource-group $resourceGroupName1 --name $kvname
az keyvault secret set --vault-name $kvname --name mongo-password --value $mongodbPassword
KEYVAULT_ID=$(az keyvault show --name ${kvname} --query id --output tsv)
az role assignment create --role Reader --assignee $spAppId --scope $KEYVAULT_ID
az keyvault set-policy -n $kvname --secret-permissions get --spn $spAppId
kubectl create secret generic kvcreds --from-literal clientid=$spAppId --from-literal clientsecret=$spPassword --type=azure/kv
kubectl create -f https://raw.githubusercontent.com/Azure/kubernetes-keyvault-flexvol/master/deployment/kv-flexvol-installer.yaml
kubectl get pods -n kv -w
kubectl apply -f captureorder-deployment-flexvol.yaml
kubectl get pod -l app=captureorder

kubectl exec captureorder-7d84d9474c-4wsff cat /kvmnt/mongo-password



##############################
#  Clean Up
##############################
az account set --subscription $subscription
az group delete --name $resourceGroupName1 --yes --no-wait
az group delete --name $resourceGroupName2 --yes --no-wait
