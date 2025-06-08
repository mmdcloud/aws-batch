resource "aws_eip" "eip" {  
  domain = var.domain
  tags = {
    Name = "${var.eip_name}"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.eip.id
  subnet_id     = var.subnet

  tags = {
    Name = "${var.nat_gw_name}"
  }
}
