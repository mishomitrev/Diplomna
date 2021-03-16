terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
   region = "eu-west-1"
}

resource "aws_s3_bucket" "images" {
  bucket = "elsys-diplom-images"
  acl    = "private"
}

module "elsys-network" {
  source                                      = "cn-terraform/terraform-aws-networking"

  name_prefix                                 = "elsys-networking"
  vpc_cidr_block                              = "192.168.0.0/16"
  availability_zones                          = ["eu-west-1a", "eu-west-1b", "eu-west-1c", "eu-west-1d"]
  public_subnets_cidrs_per_availability_zone  = ["192.168.0.0/19", "192.168.32.0/19", "192.168.64.0/19", "192.168.96.0/19"]
  private_subnets_cidrs_per_availability_zone = ["192.168.128.0/19", "192.168.160.0/19", "192.168.192.0/19", "192.168.224.0/19"]
}

module "elsys-ecs" {
  source              = "cn-terraform/terraform-aws-ecs-fargate"

  name_prefix         = "elsys"
  vpc_id              = module.elsys-network.vpc_id
  container_image     = "mihailmitrev/tuesalpr"
  container_name      = "alpr"
  public_subnets_ids  = module.elsys-network.public_subnets_ids
  private_subnets_ids = module.elsys-network.private_subnets_ids
}

module "lambda_function" { # TODO: Change var names
  source = "terraform-aws-modules/terraform-aws-lambda"

  function_name = "${random_pet.this.id}-lambda-existing-package-local"
  description   = "My awesome lambda function"
  handler       = "index.lambda_handler"
  runtime       = "python3.8"
  publish       = true

  create_package         = false
  local_existing_package = "./code/python3.8-zip/existing_package.zip"
  #  s3_existing_package = {
  #    bucket = "humane-bear-bucket"
  #    key = "builds/506df8bef5a4fb01883cce3673c9ff0ed88fb52e8583410e0cca7980a72211a0.zip"
  #    version_id = null
  #  }

  layers = [
    module.lambda_layer_local.this_lambda_layer_arn,
    module.lambda_layer_s3.this_lambda_layer_arn,
  ]
}

module "api_gateway" { # TODO: Change variables
  source = "terraform-aws-modules/terraform-aws-apigateway-v2"

  name          = "${random_pet.this.id}-http"
  description   = "My awesome HTTP API Gateway"
  protocol_type = "HTTP"

  cors_configuration = {
    allow_headers = ["content-type", "x-amz-date", "authorization", "x-api-key", "x-amz-security-token", "x-amz-user-agent"]
    allow_methods = ["*"]
    allow_origins = ["*"]
  }

  domain_name                 = local.domain_name
  domain_name_certificate_arn = module.acm.this_acm_certificate_arn

  default_stage_access_log_destination_arn = aws_cloudwatch_log_group.logs.arn
  default_stage_access_log_format          = "$context.identity.sourceIp - - [$context.requestTime] \"$context.httpMethod $context.routeKey $context.protocol\" $context.status $context.responseLength $context.requestId $context.integrationErrorMessage"

  integrations = {
    "ANY /" = {
      lambda_arn             = module.elsys-ecr.aws_lb_lb_dns_name
      payload_format_version = "2.0"
      timeout_milliseconds   = 12000
    }

    "GET /status" = {
      lambda_arn             = module.lambda_function.this_lambda_function_arn
      payload_format_version = "2.0"
      authorization_type     = "JWT"
      authorizer_id          = aws_apigatewayv2_authorizer.some_authorizer.id
    }

    "GET /recognise" = {
      lambda_arn             = module.lambda_function.this_lambda_function_arn
      payload_format_version = "2.0"
      authorization_type     = "JWT"
      authorizer_id          = aws_apigatewayv2_authorizer.some_authorizer.id
    }

    "GET /new-reg" = {
      lambda_arn             = module.lambda_function.this_lambda_function_arn
      payload_format_version = "2.0"
      authorization_type     = "JWT"
      authorizer_id          = aws_apigatewayv2_authorizer.some_authorizer.id
    }

    "$default" = {
      lambda_arn = module.lambda_function.this_lambda_function_arn
    }

  }

  tags = {
    Name = "dev-api-new"
  }
}
