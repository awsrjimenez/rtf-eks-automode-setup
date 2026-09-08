# Running RTF on EKS Auto Mode with Claude Code

This guide walks through the one-time Anypoint setup needed before running
the RTF-on-EKS-Auto-Mode automation, and what to expect once you start it.

## Prerequisites

- AWS CLI, `eksctl`, `kubectl`, and `helm` installed, with AWS credentials
  configured (`aws sts get-caller-identity` should return your identity)
- Claude Code installed (VS Code extension, desktop app, or CLI)
- Your Mule Enterprise license file (`license.lic`)
- A domain or subdomain you own, with access to add a DNS record

## One-Time Anypoint Setup

You only need to do this once per Anypoint organization.

### 1. Get Your Organization ID

1. In Anypoint Platform, go to **Access Management**
2. Click on your organization (or the specific Business Group you want to
   use)
3. On the **Settings** tab, copy the **Business Group ID** — this is your
   `ORG_ID`

### 2. Create a Connected App

This lets the automation authenticate to Anypoint without a human logging
in each time.

1. **Access Management → Connected Apps → Create App**
2. Give it a name (e.g. `RTF Automation`)
3. Select **App acts on its own behalf (Client Credentials)**
4. Add these scopes:
   - **Runtime Manager → Manage Runtime Fabrics**
   - **Runtime Manager → Read Runtime Fabrics**
   - **General → View Environment**
5. **Important:** for each scope, click **Manage** and confirm both the
   correct **Business Group** and the specific **Environment(s)** you plan
   to use (e.g. Sandbox) are checked — not just the Business Group. If an
   environment isn't checked here, the automation will get an empty
   result with no error message, which looks identical to a wrong Org ID.
6. Save, then copy the **Client ID** and **Client Secret** shown — you
   won't be able to see the secret again later

## Running It

Get the code and open it in Claude Code (VS Code, desktop, or CLI):

```bash
git clone https://github.com/awsrjimenez/rtf-eks-automode-setup.git
cd rtf-eks-automode-setup
```

Then just tell Claude Code:

```
Run through the RTF on EKS Auto Mode setup from scratch.
```

### How Configuration Works

If a file called `rtf-config.env` already exists in the project folder,
Claude Code uses those values automatically with no prompting.

If it doesn't exist, Claude Code will **prompt you for what it needs**:

| Value | Required? | Default if not provided | Where to get it |
|---|---|---|---|
| `ORG_ID` | Yes | — | Access Management → Business Group Settings |
| `CLIENT_ID` | Yes | — | Your Connected App |
| `CLIENT_SECRET` | Yes | — | Your Connected App |
| `DOMAIN` | Yes | — | A domain/subdomain you own |
| `FABRIC_NAME` | No | `rtf-automode-poc` | Any name you'd like |
| `REGION` | No | `us-east-1` | Any AWS region you want to deploy into |
| `ENVIRONMENT_NAME` | No | `Sandbox` | Any Anypoint environment name |

## What Happens After It Runs

Once everything completes, Claude Code will report that all validation
checks passed — cluster active, Auto Mode fully enabled, the load
balancer controller and RTF agent healthy, and the ingress configuration
applied.

One manual step remains by design — a real DNS record only you can add.
Claude Code will give you something like:

```
Type: CNAME
Name: *.rtf
Data: k8s-xxxxxxxxxx-xxxxxxxxxx.us-east-1.elb.amazonaws.com
```

Add that record at whatever DNS provider manages your domain. Once it
propagates (usually a few minutes), apps deployed through Runtime Manager
are reachable at:

```
http://<app-name>.<your-subdomain>.<your-domain>/
```

with **zero changes to the app itself**. No further steps or re-runs are
needed once DNS is live — just deploy an app in Runtime Manager and test
it.
