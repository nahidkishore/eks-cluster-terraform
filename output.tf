output "cluster_id" {
  value = aws_eks_cluster.nahid.id
}

output "node_group_id" {
  value = aws_eks_node_group.nahid.id
}

output "vpc_id" {
  value = aws_vpc.nahid_vpc.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
