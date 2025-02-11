package repository
import data.common.webhooks as webhookUtils

# METADATA
# scope: rule
# title: Repository not maintained
# description: There hasn't been any commits in tha last 3 months. A project which is not active might not be patched against security issues within its code and dependencies, and is therefore at higher risk of including unpatched vulnerabilities.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Either Delete or Archive the repository]
#   severity: HIGH
#   requiredScopes: [repo]
default repository_not_maintained = false

repository_not_maintained {
    not input.repository.is_archived
    not is_null(input.repository.pushed_at)
    ns := time.parse_rfc3339_ns(input.repository.pushed_at)
    now := time.now_ns()
    diff := time.diff(now, ns)
    monthsIndex := 1
    inactivityMonthsThreshold := 3
    diff[monthsIndex] >= inactivityMonthsThreshold
}

repository_not_maintained {
    not input.repository.is_archived
    not is_null(input.repository.pushed_at)
    ns := time.parse_rfc3339_ns(input.repository.pushed_at)
    now := time.now_ns()
    diff := time.diff(now, ns)
    yearIndex := 0
    diff[yearIndex] > 0
}

# METADATA
# scope: rule
# title: Repository Has Too Many Admins
# description: Repository are admins highly privileged and could create great damage if being compromised, it's recommeneded to limit them to the minimum required (recommended maximum 3 admins).
# custom:
#   severity: LOW
#   remediationSteps: [Make sure you have admin permissions, Go to the repository settings page, Press "Collaborators and teams", Select the unwanted admin users, Select "Change Role"]
#   requiredScopes: [read:org,repo]
default repository_has_too_many_admins  = false
repository_has_too_many_admins {
    admins := [admin | admin := input.collaborators[_]; admin.permissions["admin"]]
    count(admins) > 3
}

# METADATA
# scope: rule
# title: Webhook Configured Without A Secret
# description: Webhooks that are not configured with a token authenticated to validate the origin of the request and could make your software vulnerable.
# custom:
#   requiredEnrichers: [hooksList]
#   severity: LOW
#   remediationSteps: [Make sure you can manage webhooks for the repository, Go to the repository settings page, Select "Webhooks", Press on the insecure webhook, Confiure a secret , Click "Update webhook"]
#   requiredScopes: [read:repo_hook, repo]
repository_webhook_no_secret[violated] = true {
    some index
    hook := input.hooks[index]
    not webhookUtils.has_secret(hook)
    violated := {
        "name": hook.name,
        "url": hook.url
    }
}

# METADATA
# scope: rule
# title: Webhook Configured Without SSL
# description: Webhooks that are not configured with SSL enabled could expose your sofware to man in the middle attacks (MITM).
# custom:
#   requiredEnrichers: [hooksList]
#   severity: LOW
#   remediationSteps: [Make sure you can manage webhooks for the repository, Go to the repository settings page, Select "Webhooks", Verify url starts with https, Press on the insecure webhook, Enable "SSL verfication", Click "Update webhook"]
#   requiredScopes: [read:repo_hook, repo]
repository_webhook_doesnt_require_ssl[violated] = true {
    some index
    hook := input.hooks[index]
    not webhookUtils.ssl_enabled(hook)
    violated := {
        "name": hook.name,
        "url": hook.url
    }
}

# METADATA
# scope: rule
# title: Forking Allowed for This Repository
# description: Forking a repository can lead to loss of control and potential exposure of the source code. The option to fork must be disabled by default and turned on only by admins deliberately when opting to create a fork. If you do not need forking, it is recommended to turn it off in the repository configuration.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "General" tab, Under "Features", Toggle off "Allow forking"]
#   severity: LOW
#   requiredScopes: [read:org]
default forking_allowed_for_repository = false
forking_allowed_for_repository {
    input.repository.is_private == true
    input.repository.allow_forking == true
}

is_null(x) {
    x == null
}

has_branch_protection_permission(_input) {
    _input.no_branch_protection_permission == false
}

has_branch_protection_info(_input) {
    has_branch_protection_permission(_input)
    not is_null(_input.repository.default_branch) # protect against empty repos 
}

# METADATA
# scope: rule
# title: Default Branch Is Not Protected
# description: Branch protection is not enabled for this repository’s default branch. Protecting branches ensures new code changes must go through a controlled merge process and allows enforcement of code review as well as other security tests. This issue is raised if the default branch protection is turned off.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Add rule", Set "Branch name pattern" as the default branch name (usually "main" or "master"), Set desired protections, Click "Create" and save the rule]
#   severity: MEDIUM
#   requiredScopes: [repo]
default missing_default_branch_protection = false
missing_default_branch_protection {
    has_branch_protection_info(input)
    is_null(input.repository.default_branch.branch_protection_rule)
}

# METADATA
# scope: rule
# title: Default Branch Could Be Deleted
# description: The history of the default branch is not protected against deletion for this repository.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab ,Under "Branch protection rules", Click "Edit" on the default branch rule, Uncheck "Allow deletions", Click "Save changes"]
#   severity: MEDIUM
#   requiredScopes: [repo]
#   threat:
#     - "Users could merge code without any restrictions which could lead to insecure code reaching your main branch and production."
default missing_default_branch_protection_deletion = false
missing_default_branch_protection_deletion {
    has_branch_protection_info(input)
	input.repository.default_branch.branch_protection_rule.allows_deletions == true
}

# METADATA
# scope: rule
# title: Default Branch Allows Force Pushes
# description: The history of the default branch is not protected against changes for this repository. Protecting branch history ensures every change that was made to code can be retained and later examined. This issue is raised if the default branch history can be modified using force push.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Uncheck "Allow force pushes", Click "Save changes"]
#   severity: MEDIUM
#   requiredScopes: [repo]
default missing_default_branch_protection_force_push = false
missing_default_branch_protection_force_push {
    has_branch_protection_info(input)
	input.repository.default_branch.branch_protection_rule.allows_force_pushes == true
}

# METADATA
# scope: rule
# title: Default Branch Doesn’t Require All Checks To Pass Before Merge
# description: Branch protection is enabled, however, the checks which validate the quality and security of the code are not required to pass before submitting new changes. The default check ensures code is up-to-date in order to prevent faulty merges and unexpected behaviors, as well as other custom checks that test security and quality. It is advised to turn this control on to ensure any existing or future check will be required to pass. This option is found in the branch protection setting for the repository.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require status checks to pass before merging", "Add the required checks that must pass before merging (tests, lint, etc...)", Click "Save changes"]
#   severity: MEDIUM
#   requiredScopes: [repo]
#   threat:
#     - "Users could merge its code without all required checks passes what could lead to insecure code reaching your main branch and production."
default requires_status_checks = false
requires_status_checks {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.requires_status_checks == false
}
# METADATA
# scope: rule
# title: Default Branch Doesn’t Require Branches To Be Up To Date Before Merge
# description: You have branch protection, but branches that are not up to date can be merged.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require status checks to pass before merging", Check "Require branches to be up to date before merging", Click "Save changes"]
#   severity: MEDIUM
#   requiredScopes: [repo]
default requires_branches_up_to_date_before_merge = false
requires_branches_up_to_date_before_merge {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.requires_strict_status_checks == false
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Require New Code Changes After Approval To Be Re-Approved
# description: This security control prevents merging code that was approved but later on changed. Turning it on ensures new changes are required to be reviewed again. This setting is part of branch protection and code-review settings, and hardens the review process. If turned off - a developer can change the code after approval, and push code that is different from the one that was previously allowed. This option is found in the branch protection setting for the repository.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require a pull request before merging", Check "Dismiss stale pull request approvals when new commits are pushed", Click "Save changes"]
#   severity: LOW
#   requiredScopes: [repo]
default dismisses_stale_reviews = false
dismisses_stale_reviews {
    has_branch_protection_info(input)
    not input.repository.default_branch.branch_protection_rule.dismisses_stale_reviews
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Require Code Review
# description: In order to comply with separation of duties principle and enforce secure code practices, a code review should be mandatory using the source-code-management built-in enforcement. This option is found in the branch protection setting of the repository.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require a pull request before merging", Check "Require approvals", Set "Required number of approvals before merging" to 1 or more, Click "Save changes"]
#   severity: HIGH
#   requiredScopes: [repo]
#   threat:
#    - "Users can merge code without being reviewed which can lead to insecure code reaching the main branch and production."
default code_review_not_required = false
code_review_not_required {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.required_approving_review_count < 1
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Require Code Review By At Least Two Reviewers
# description: In order to comply with separation of duties principle and enforce secure code practices, a code review should be mandatory using the source-code-management built-in enforcement. This option is found in the branch protection setting of the repository.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require a pull request before merging", Check "Require approvals", Set "Required number of approvals before merging" to 1 or more, Click "Save changes"]
#   severity: MEDIUM
#   requiredScopes: [repo]
#   threat:
#    - "Users can merge code without being reviewed which can lead to insecure code reaching the main branch and production."
default code_review_by_two_members_not_required = false
code_review_by_two_members_not_required {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.required_approving_review_count < 2
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Limit Code Review to Code-Owners
# description: It is recommended to require code review only from designated individuals specified in CODEOWNERS file. Turning this option on enforces that only the allowed owners can approve a code change. This option is found in the branch protection setting of the repository.
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require a pull request before merging", Check "Require review from Code Owners", Click "Save changes"]
#   severity: LOW
#   requiredScopes: [repo]
default code_review_not_limited_to_code_owners = false
code_review_not_limited_to_code_owners {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.requires_code_owner_reviews == false
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Require Linear History
# description: Prevent merge commits from being pushed to protected branches.
# custom:
#    remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require linear history", Click "Save changes"]
#    severity: MEDIUM
#    requiredScopes: [repo]
default non_linear_history = false
non_linear_history {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.requires_linear_history == false
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Require All Conversations To Be Resolved Before Merge
# description: Require all Pull Request conversations to be resolved before merging. Check this to avoid bypassing/missing a Pull Reuqest comment.
# custom:
#    remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require conversation resolution before merging", Click "Save changes"]
#    severity: LOW
#    requiredScopes: [repo]
default no_conversation_resolution = false
no_conversation_resolution {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.requires_conversation_resolution == false
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Require All Commits To Be Signed
# description: Require all commits to be signed and verified
# custom:
#    remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Require signed commits", Click "Save changes"]
#    severity: LOW
#    requiredScopes: [repo]
default no_signed_commits = false
no_signed_commits {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.requires_commit_signatures == false
}

# METADATA
# scope: rule
# title: Default Branch Doesn't Restrict Who Can Dismiss Reviews
# description: Any user with write access to the repository can dismiss pull-request reviews. Pull-request review contains essential information on the work that needs to be done and helps keep track of the changes. Dismissing it might cause a loss of this information and should be restricted to a limited number of users.
# custom:
#    remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Restrict who can dismiss pull request reviews", Click "Save changes"]
#    severity: LOW
#    requiredScopes: [repo]
default review_dismissal_allowed = false
review_dismissal_allowed {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.restricts_review_dismissals == false
}

# METADATA
# scope: rule
# title: Default Branch Allows Pushes to Protected Branch
# description: By default, commits can be pushed directly to protected branches, without going through a Pull Request. Restrict pushes to protected branches so that commits can be added only via merges, which require Pull Request.
# custom:
#    remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Branches" tab, Under "Branch protection rules", Click "Edit" on the default branch rule, Check "Restrict who can push to matching branches", Click "Save changes"]
#    severity: MEDIUM
#    requiredScopes: [repo]
default pushes_are_not_restricted = false
pushes_are_not_restricted {
    has_branch_protection_info(input)
    input.repository.default_branch.branch_protection_rule.restricts_pushes == false
}

# METADATA
# scope: rule
# title: Vulnerability Alerts Is Not Enabled
# description: Enable GitHub Dependabot to continuously scan for open source vulnerabilities and receive alerts
# custom:
#   remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Code security and analysis" tab, Set "Dependabot alerts" as Enabled]
#   severity: MEDIUM
#   requiredScopes: [repo]
default vulnerability_alerts_not_enabled = false
vulnerability_alerts_not_enabled {
    # deliberately ignoring nil value (in case this data is unavailable)
    input.vulnerability_alerts_enabled == false
}

# METADATA
# scope: rule
# title: GitHub Advanced Security – Dependency Review Is Disabled For A Repository
# description: Enable GitHub Advanced Security dependency review to avoid introducing new vulnerabilities
# custom:
#    remediationSteps: [Make sure you have admin permissions, Go to the repo's settings page, Enter "Code security and analysis" tab, Set "Dependency graph" as Enabled]
#    severity: MEDIUM
#    requiredScopes: [repo]
#    threat:
#      - "A user can add dependencies to vulnerable third-party dependencies therefore introducing vulnerabilities to your application."
default ghas_dependency_review_not_enabled = false
ghas_dependency_review_not_enabled {
    input.dependency_graph_manifests.total_count == 0
}

# METADATA
# scope: rule
# title: Low scorecard score for repository indicates poor security posture
# description: Scorecard is an open-source tool from OSSF that helps to asses the security posture of repositories, Low scorecard score means your repository may be under risk.
# custom:
#    requiredEnrichers: [scorecard]
#    remediationSteps: [Get scorecard output by either:, "- Run legitify with --scorecard verbose", "- Run scorecard manually", Fix the failed checks]
#    severity: MEDIUM
#    requiredScopes: [repo, read:repo_hook]
#    prerequisites: [scorecard_enabled]
default scorecard_score_too_low = false
scorecard_score_too_low {
    not is_null(input.scorecard)
    input.scorecard.score < 7.0
}

# METADATA
# scope: rule
# title: Default workflow token permission is not read only
# description: Your default GitHub Action workflow token permission is set to read-write. When creating workflow tokens, it is highly recommended to follow the Principle of Least Privilege and force workflow authors to specify explicitly which permissions they need.
# custom:
#   requiredEnrichers: [organizationId]
#   remediationSteps:
#     - Make sure you have admin permissions
#     - Go to the org's settings page
#     - Enter "Actions - General" tab
#     - Under 'Workflow permissions'
#     - Select 'Read repository contents permission'
#     - Click 'Save'
#   severity: MEDIUM
#   requiredScopes: [admin:org]
#   threat: In case of token compromise (due to a vulnerability or malicious third-party GitHub actions), an attacker can use this token to sabotage various assets in your CI/CD pipeline, such as packages, pull-requests, deployments, and more.
default token_default_permissions_is_read_write  = false
token_default_permissions_is_read_write {
    input.actions_token_permissions.default_workflow_permissions != "read"
}

# METADATA
# scope: rule
# title: Workflows Are Allowed To Approve Pull Requests
# description: Your default GitHub Actions configuration allows for workflows to approve pull requests. This could allow users to bypass code-review restrictions.
# custom:
#   requiredEnrichers: [organizationId]
#   remediationSteps:
#     - Make sure you have admin permissions
#     - Go to the org's settings page
#     - Enter "Actions - General" tab
#     - Under 'Workflow permissions'
#     - Uncheck 'Allow GitHub actions to create and approve pull requests.
#     - Click 'Save'
#   severity: HIGH
#   requiredScopes: [admin:org]
#   threat: Attackers can exploit this misconfiguration to bypass code-review restrictions by creating a workflow that approves their own pull request and then merging the pull request without anyone noticing, introducing malicious code that would go straight ahead to production.
default actions_can_approve_pull_requests  = false
actions_can_approve_pull_requests {
    input.actions_token_permissions.can_approve_pull_request_reviews
}
