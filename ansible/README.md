# Set up your EC2 machine with Ansible

Four small playbooks, each doing one job. Run them all at once, or one at a time.

```
ansible/
  inventory.ini              which machine to set up
  group_vars/nexabank.yml    all settings in one place

  01-install-tools.yml       apt packages, AWS CLI v2, Terraform, kubectl, Helm, gh
  02-configure-aws.yml       AWS region, optional keys, `k` alias + kubectl completion
  03-clone-repo.yml          clone the NexaBank repo
  04-verify.yml              check everything works (incl. Terraform >= 1.11 and AWS login)

  site.yml                   runs 01 -> 04 in order
```

Installs **AWS CLI v2, Terraform, kubectl, Helm, jq, dig, git, gh**. No Docker: GitHub Actions
builds the images and ArgoCD deploys them, so this machine never needs it.

## What you need

- The EC2 machine you launched (DEPLOY.md step 1: Ubuntu 24.04, SSH from your IP, an IAM role attached) and your `.pem` key
- Ansible on your laptop: `pip install ansible` (or `brew install ansible`)

## Run it

```bash
# 1. inventory: add your machine's IP/user/key (or keep `localhost` and run this on the machine itself)
vi inventory.ini

# 2. settings: at least repo_url if you use a fork
vi group_vars/nexabank.yml

# 3. go (must be run from this folder so group_vars/ is found)
cd ansible
ansible-playbook -i inventory.ini site.yml
```

Then:

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@<ec2-ip>
aws sts get-caller-identity       # shows the IAM role attached to the instance
cd NexaBank && less DEPLOY.md
```

You can also run Ansible **on the EC2 machine itself** against `localhost` (the default inventory line):
copy the folder over, `pip install ansible`, run the same command.

## One piece at a time

```bash
ansible-playbook -i inventory.ini 02-configure-aws.yml      # changed region/keys
ansible-playbook -i inventory.ini 04-verify.yml             # is the box still healthy?
ansible-playbook -i inventory.ini site.yml --check          # dry run
```

All playbooks are safe to re-run.

## About AWS credentials

Leave `aws_access_key` empty: the instance's IAM role is found automatically (nothing to leak or rotate).
If you must use keys, encrypt them: `ansible-vault encrypt_string 'AKIA...' --name aws_access_key`
and run with `--ask-vault-pass`.

## If something breaks

| Problem | Fix |
| --- | --- |
| `UNREACHABLE` / permission denied | `chmod 400 key.pem`; security group must allow SSH from your *current* IP |
| `undefined variable` | you ran from outside `ansible/`; `cd ansible` first |
| Wrong user | Amazon Linux uses `ec2-user`; these playbooks expect Ubuntu |
| `04-verify` says AWS credentials do not work | the instance has no IAM role: attach an IAM role to the instance (EC2 → Actions → Security → Modify IAM role), or set keys |
