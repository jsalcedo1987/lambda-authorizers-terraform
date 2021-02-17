provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# This node creates an API Gateway
resource "aws_api_gateway_rest_api" "api" {
  name = "authorization-api"
}

# This attachs a resource (e.g /) to the gateway
resource "aws_api_gateway_resource" "resource" {
  path_part   = "demo"
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  rest_api_id = aws_api_gateway_rest_api.api.id
}

# This node attached a method to the previous resource
resource "aws_api_gateway_method" "method" {
  rest_api_id        = aws_api_gateway_rest_api.api.id
  resource_id        = aws_api_gateway_resource.resource.id
  http_method        = "GET"
  authorization      = "CUSTOM"
  request_parameters = { "method.request.header.jwt" = false } // Http Request header
  authorizer_id      = aws_api_gateway_authorizer.ApiAuthoriserJwt.id
}


# Lambda integration request
resource "aws_api_gateway_integration" "integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.resource.id
  http_method             = aws_api_gateway_method.method.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = aws_lambda_function.lambda_authorization.invoke_arn
  passthrough_behavior    = "WHEN_NO_TEMPLATES"
  request_templates = { # Not documented
    "application/json" = "${file("mapping-template/api_gateway_jwt_mapping.template")}"
  }
}



resource "null_resource" "method-delay" {
  provisioner "local-exec" {
    command = "sleep 15"
  }
  triggers = {
    response = aws_api_gateway_resource.resource.id
  }
}



# Lambda integration response
resource "aws_api_gateway_method_response" "response_200" {
  depends_on  = [null_resource.method-delay]
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.method.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

}

resource "aws_api_gateway_integration_response" "api_integration_response" {
  depends_on  = [null_resource.method-delay]
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.method.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code

  # Transforms the backend JSON response to XML
  response_templates = {
    "application/json" = <<EOF
EOF
  }
}


# Gateway deployment
resource "aws_api_gateway_deployment" "gateway_deployment" {
  depends_on  = [aws_api_gateway_integration.integration]
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "production"
}

# Lambda
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_authorization.function_name
  principal     = "apigateway.amazonaws.com"
  # More: http://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-control-access-using-iam-policies-to-invoke-api.html
  source_arn = "arn:aws:execute-api:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.api.id}/*/${aws_api_gateway_method.method.http_method}${aws_api_gateway_resource.resource.path}"
}

# Role to execute the lambda
resource "aws_iam_role" "demo_lambda_role" {
  name = "demo_lambda_role"

  assume_role_policy = <<-EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
  EOF
}


data "archive_file" "lambda_example_zip" {
  type        = "zip"
  source_dir  = "example-lambda"
  output_path = "example.zip"
}



# Actual lambda code 
resource "aws_lambda_function" "lambda_authorization" {
  filename         = "example.zip"
  function_name    = "ApiLambdaExample"
  handler          = "index.handler"
  runtime          = "nodejs12.x"
  source_code_hash = data.archive_file.lambda_example_zip.output_base64sha256
  role             = aws_iam_role.demo_lambda_role.arn
}




// Authoriser

resource "aws_api_gateway_authorizer" "ApiAuthoriserJwt" {
  name                             = "ApiAuthoriserJwt"
  rest_api_id                      = aws_api_gateway_rest_api.api.id
  authorizer_uri                   = aws_lambda_function.authorizer.invoke_arn
  authorizer_credentials           = aws_iam_role.invocation_role.arn
  authorizer_result_ttl_in_seconds = 0
}


resource "aws_iam_role" "invocation_role" {
  name = "api_gateway_auth_invocation"
  path = "/"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "invocation_policy" {
  name = "default"
  role = aws_iam_role.invocation_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "lambda:InvokeFunction",
      "Effect": "Allow",
      "Resource": "${aws_lambda_function.authorizer.arn}"
    }
  ]
}
EOF
}

resource "aws_iam_role" "lambda" {
  name = "demo-lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

data "archive_file" "lambda_authoriser_zip" {
  type        = "zip"
  source_dir  = "authoriser-lambda"
  output_path = "authoriser.zip"
}

resource "aws_lambda_function" "authorizer" {
  filename         = "authoriser.zip"
  function_name    = "api_gateway_authorizer"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs12.x"
  source_code_hash = data.archive_file.lambda_authoriser_zip.output_base64sha256
}

// Authoriser


## API URL
output "api_endpoint_url" {
  value = "${aws_api_gateway_deployment.gateway_deployment.invoke_url}/demo"
}
