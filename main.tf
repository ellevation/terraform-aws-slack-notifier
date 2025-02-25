terraform {
  required_version = ">= 0.12"
}

data "aws_iam_policy" "cloudwatch_readonly" {
  arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

data "archive_file" "deployment_package" {
  type        = "zip"
  source_dir  = "${path.module}/vendor/aws-to-slack/build"
  output_path = "${path.module}/aws-to-slack.zip"
}

module "lambda" {
  source = "git::https://github.com/ellevation/terraform-aws-lambda.git"

  function_name = var.name
  description   = "Post messages from AWS to Slack"
  handler       = "src/index.handler"
  runtime       = "nodejs14.x"
  timeout       = 10

  deployment_package_path = data.archive_file.deployment_package.output_path

  policy = {
    json = data.aws_iam_policy.cloudwatch_readonly.policy
  }

  environment = {
    variables = {
      DEFAULT_SLACK_HOOK_URL   = var.default_hook_url
      SLACK_HOOK_URL_OVERRIDES = jsonencode(var.hook_url_overrides)
    }
  }
}

resource "aws_cloudwatch_event_rule" "this" {
  count = length(var.event_rules)

  name = lookup(
    var.event_rules[count.index],
    "name",
    "${var.name}_${count.index}",
  )
  description = lookup(
    var.event_rules[count.index],
    "description",
    "Managed by Terraform",
  )
  event_pattern = var.event_rules[count.index]["pattern"]
}

resource "aws_cloudwatch_event_target" "this" {
  count = length(var.event_rules)

  rule = aws_cloudwatch_event_rule.this[count.index].name
  arn  = module.lambda.function_arn
}

resource "aws_lambda_permission" "lambda" {
  count = length(var.event_rules)

  action        = "lambda:InvokeFunction"
  function_name = module.lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.this[count.index].arn
}

resource "aws_sns_topic" "this" {
  count = var.create_sns_topic ? 1 : 0

  name = var.name
}

resource "aws_sns_topic_subscription" "this" {
  for_each = var.create_sns_topic ? { "arn" : aws_sns_topic.this[0].arn } : { for arn in var.sns_topics : arn => arn }

  topic_arn = each.value
  protocol  = "lambda"
  endpoint  = module.lambda.function_arn
}

resource "aws_lambda_permission" "sns" {
  for_each = var.create_sns_topic ? { "arn" : aws_sns_topic.this[0].arn } : { for arn in var.sns_topics : arn => arn }

  action        = "lambda:InvokeFunction"
  function_name = module.lambda.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = each.value
}
