output "cluster_name"         { value = aws_eks_cluster.main.name }
output "cluster_endpoint"     { value = aws_eks_cluster.main.endpoint }
output "ecr_repository_url"   { value = aws_ecr_repository.app.repository_url }
output "kubectl_config_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}
output "docker_login_command" {
  value = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.app.repository_url}"
}
