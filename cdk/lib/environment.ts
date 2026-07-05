const DEFAULT_ENVIRONMENT_NAME = "dev";
const PROD_REGION = "us-east-1";
const DEV_REGION = "us-west-2";

export class Environment {
  static fromName(name?: string, accountId?: string): Environment {
    return new Environment(name || DEFAULT_ENVIRONMENT_NAME, accountId);
  }

  private constructor(
    readonly name: string,
    readonly accountId?: string,
  ) {}

  get isDev(): boolean {
    return this.name === "dev";
  }

  get isProd(): boolean {
    return this.name === "prod";
  }

  get region(): string {
    return this.isProd ? PROD_REGION : DEV_REGION;
  }

  acmCertificateArn(certificateId: string): string {
    return `arn:aws:acm:${PROD_REGION}:${this.accountId}:certificate/${certificateId}`;
  }
}
