variable "budget_email" {
  description = "Email address for budget alerts"
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_email))
    error_message = "budget_email must be an email address."
  }
}

variable "budget_usd" {
  description = "Monthly budget alert threshold in USD"
  type        = string
  default     = "10"
}
