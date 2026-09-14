// GitHub Actions OIDC trust-policy literals.
//
// These two strings are the mechanism that stops an arbitrary caller from
// assuming a deploy role: the issuer host names the provider GitHub signs
// tokens as, and the audience is the value GitHub puts in the token's `aud`
// claim when a workflow requests AWS credentials. They were retyped inline at
// every trust-policy site (here and in EdgeVector/exemem-infra); a typo in one
// copy would either lock CI out or, worse, widen who a role trusts. Keep one
// definition per repo and build the provider, every ARN and every condition
// key from it.
//
// EdgeVector/exemem-infra carries the same module with the same values.

// Issuer host of the GitHub Actions OIDC provider. Also the IAM condition-key
// prefix (`<host>:aud`, `<host>:sub`) and the provider ARN suffix.
export const GITHUB_OIDC_ISSUER_HOST = "token.actions.githubusercontent.com";

// Issuer URL the IAM OpenIdConnectProvider resource is created with.
export const GITHUB_OIDC_ISSUER_URL = `https://${GITHUB_OIDC_ISSUER_HOST}`;

// Audience GitHub places in the token's `aud` claim for AWS credential requests.
export const GITHUB_OIDC_AUDIENCE = "sts.amazonaws.com";

// IAM condition keys the trust policy tests, built from the issuer host.
export const GITHUB_OIDC_AUD_CONDITION_KEY = `${GITHUB_OIDC_ISSUER_HOST}:aud`;
export const GITHUB_OIDC_SUB_CONDITION_KEY = `${GITHUB_OIDC_ISSUER_HOST}:sub`;
