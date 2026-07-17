const DEFAULT_ENVIRONMENT_NAME = "dev";
const PROD_REGION = "us-east-1";
const DEV_REGION = "us-west-2";
const LOCAL_SCHEMA_FRONTEND_ORIGINS = [
  "http://localhost:8080",
  "http://127.0.0.1:8080",
];
const PROD_SCHEMA_FRONTEND_ORIGINS = ["https://schema.folddb.com"];

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

  get schemaHttpApiCorsAllowOrigins(): string[] {
    if (this.isProd) {
      return [...PROD_SCHEMA_FRONTEND_ORIGINS, ...LOCAL_SCHEMA_FRONTEND_ORIGINS];
    }

    return [...LOCAL_SCHEMA_FRONTEND_ORIGINS, ...PROD_SCHEMA_FRONTEND_ORIGINS];
  }

  acmCertificateArn(certificateId: string): string {
    return `arn:aws:acm:${PROD_REGION}:${this.accountId}:certificate/${certificateId}`;
  }
}
