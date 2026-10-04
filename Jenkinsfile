// =============================================================================
//  Generic DevSecOps pipeline  -  ONE Jenkinsfile for Docker AND .NET/IIS apps
//
//  Checkout > Detect > Restore > Build > Test > SonarQube > OWASP > Trivy > SECURITY GATE
//          > (production approval) > DOCKER  : build > image scan > push > deploy > health check
//                                  > IIS     : publish > backup > deploy > recycle pool > health check
//          > automatic rollback on failure > notifications
//
//  WHICH STAGE RUNS ON WHICH AGENT
//    Linux   (AGENT_BUILD,  default label linux-docker): checkout, restore, build, test, SonarQube, OWASP, Trivy fs, security gate
//    Linux   (AGENT_DOCKER, default label linux-docker): docker build, Trivy image scan, registry push, container deploy, health check
//    Windows (AGENT_IIS,    default label windows-iis ): dotnet publish, IIS backup, deploy, app pool recycle, health check
//    (the controller runs nothing but the lightweight "Initialize" and "Approval" steps)
//
//  HOW TO USE FOR A NEW APPLICATION
//    1. Copy this Jenkinsfile (and the scripts/ folder, or set SCRIPTS_REPO_URL) into your repository.
//    2. Edit ONLY the CFG block below. Never put passwords/tokens here - only Jenkins credential IDs.
//    3. Create the Jenkins job (see docs/jenkins-setup.md) and run it once manually.
// =============================================================================
import groovy.transform.Field

// -----------------------------------------------------------------------------
//  CFG  -  the ONLY section you edit per application
// -----------------------------------------------------------------------------
@Field Map CFG = [

    // ======================= 1. APPLICATION =======================
    APP_NAME            : 'devsecops-demo',                 // letters, digits, . _ -   (used for names, backups, state folders)
    APP_TYPE            : 'auto',                   // auto | dotnet | node | python | docker | generic
    DEPLOY_TYPE         : 'docker',                 // default of the DEPLOY_TYPE parameter: docker | iis | none (none = CI + security only)
    DEFAULT_ENVIRONMENT : 'dev',                    // dev | staging   (webhook builds always use this one; production is never the default)

    // ======================= 2. SOURCE CONTROL =======================
    REPO_URL            : 'https://github.com/AbhishekChauhan1101/devsecops-demo-app.git',    // https://github.com/<org>/<repo>.git  or  https://bitbucket.org/<ws>/<repo>.git
    BRANCH              : 'main',
    GIT_CREDENTIALS_ID  : '',        // Jenkins credential (Username+token / SSH key). '' = public repo
    USE_JOB_SCM         : false,                    // true = this Jenkinsfile comes from "Pipeline script from SCM" and THAT checkout is built
    SCRIPTS_REPO_URL    : '',                       // optional: central repo that contains the scripts/ folder (instead of copying it)
    SCRIPTS_REPO_BRANCH : 'main',
    SCRIPTS_REPO_CRED_ID: '',

    // ======================= 3. TRIGGERS =======================
    WEBHOOK_TOKEN_CRED_ID: 'webhook-token',         // "Secret text" credential holding the Generic Webhook Trigger token
    POLL_SCM_CRON        : '',                      // fallback polling, e.g. 'H H/6 * * *'. '' = disabled (use the webhook)

    // ======================= 4. FEATURE SWITCHES (what this application uses) =======================
    ENABLE_TESTS        : true,
    ENABLE_SONARQUBE    : false,
    ENABLE_OWASP        : false,
    ENABLE_TRIVY        : false,

    // ======================= 5. BUILD =======================
    INSTALL_COMMAND     : '',                       // optional custom command; overrides the built-in restore/install
    BUILD_COMMAND       : '',                       // optional custom command; overrides the built-in build
    TEST_COMMAND        : '',                       // optional custom command; overrides the built-in test
    DOTNET_SOLUTION     : '',                       // e.g. 'src/MyApp.sln'   (empty = auto-detect a single .sln)
    DOTNET_PROJECT      : '',                       // web project to publish for IIS, e.g. 'src/MyApp.Web/MyApp.Web.csproj'
    DOTNET_TEST_PROJECT : '',                       // optional; empty = tests are discovered from the solution
    DOTNET_CONFIGURATION: 'Release',
    DOTNET_PUBLISH_ARGS : '',                       // e.g. '-r win-x64 --self-contained false'

    // ======================= 6. SONARQUBE =======================
    SONAR_SERVER_NAME   : 'sonarqube',              // name of the server in Manage Jenkins > System > SonarQube servers (holds the token)
    SONAR_PROJECT_KEY   : '',                       // empty = APP_NAME
    SONAR_PROJECT_NAME  : '',                       // empty = APP_NAME
    SONAR_SCANNER_TOOL  : '',                       // Jenkins "SonarQube Scanner" tool name for non-.NET apps ('' = sonar-scanner on PATH)
    SONAR_AUTH_PROPERTY : 'sonar.token',            // 'sonar.login' for SonarQube older than 10
    SONAR_DOTNET_AUTO_INSTALL: false,               // true = install dotnet-sonarscanner automatically on the agent
    SONAR_EXTRA_ARGS    : '',                       // .NET: '/d:sonar.exclusions=**/Migrations/**'   other: '-Dsonar.exclusions=...'
    SONAR_SOURCES       : '.',                      // non-.NET apps: folders to analyse (sonar.sources)
    SONAR_QUALITY_GATE  : true,                     // wait for the Quality Gate result (needs the SonarQube -> Jenkins webhook)
    SONAR_QG_TIMEOUT_MIN: 10,
    SONAR_POLICY        : 'fail',                   // when the Quality Gate fails: fail | unstable | ignore

    // ======================= 7. OWASP DEPENDENCY-CHECK =======================
    OWASP_DC_HOME       : '',                       // install folder of dependency-check ('' = dependency-check.sh on PATH)
    OWASP_FAIL_THRESHOLD: 7,                        // fail on CVSS >= this value (0-10). 11 = report only
    OWASP_SCAN_PATH     : '.',
    OWASP_DATA_DIR      : '',                       // persistent NVD cache folder on the agent (strongly recommended)
    OWASP_NVD_API_KEY_CRED_ID: '',                  // optional "Secret text" credential with an NVD API key
    OWASP_EXTRA_ARGS    : '',                       // e.g. '--exclude **/node_modules/**'
    OWASP_POLICY        : 'fail',                   // fail | unstable | ignore

    // ======================= 8. TRIVY =======================
    TRIVY_SEVERITY      : 'HIGH,CRITICAL',
    TRIVY_EXIT_CODE     : 1,                        // exit code when findings exist at TRIVY_SEVERITY. 0 = report only
    TRIVY_FS_SCAN       : 'auto',                   // filesystem scan of the source: auto (= when NOT deploying a container) | true | false
    TRIVY_SCANNERS      : 'vuln,secret',            // add ',misconfig' to scan Dockerfile/IaC
    TRIVY_IGNORE_UNFIXED: false,
    TRIVY_SKIP_DIRS     : '',                       // comma separated, e.g. 'node_modules,.git'
    TRIVY_USE_DOCKER    : false,                    // true = run the aquasec/trivy container instead of a local trivy binary
    TRIVY_DOCKER_TAG    : 'latest',                 // image tag of aquasec/trivy when TRIVY_USE_DOCKER is true (pin a version in production)
    TRIVY_CACHE_DIR     : '',                       // persistent vulnerability-DB cache on the agent ('' = default)
    TRIVY_TIMEOUT       : '10m',
    TRIVY_POLICY        : 'fail',                   // fail | unstable | ignore

    // ======================= 9. SECURITY GATE =======================
    SECURITY_GATE       : 'enforce',                // enforce (secure default) | warn (downgrade failures to UNSTABLE) | off

    // ======================= 10. DOCKER DEPLOYMENT =======================
    DOCKERFILE_PATH     : 'Dockerfile',
    DOCKER_CONTEXT      : '.',
    DOCKER_IMAGE        : '',                       // image name without registry. Empty = APP_NAME
    DOCKER_CONTAINER    : '',                       // container name. Empty = APP_NAME
    DOCKER_HOST_PORT    : '8080',                   // '' = do not publish a port
    DOCKER_CONTAINER_PORT: '8080',
    DOCKER_NETWORK      : '',
    DOCKER_BUILD_ARGS   : '',                       // e.g. '--build-arg BUILD_CONFIGURATION=Release'   (never pass secrets)
    DOCKER_EXTRA_RUN_ARGS: '',                      // e.g. '--memory 512m --cpus 1'
    DOCKER_ENV_FILE     : '',                       // runtime env file that already exists ON THE HOST (outside Git)
    DOCKER_ENV_FILE_CRED_ID: '',                    // OR a Jenkins "Secret file" credential that is used as the env file
    DOCKER_KEEP_IMAGES  : 5,                        // old images of this repository kept on the deploy host
    DOCKER_PUSH_LATEST  : false,                    // keep false - immutable tags only (BUILD_NUMBER-GITSHA)
    DOCKER_PRUNE        : true,                     // prune dangling images after the build
    DOCKER_KEEP_PREVIOUS_CONTAINER: false,          // keep the stopped <name>-previous container after a successful deploy
    DOCKER_ALLOW_NEW_PRIVILEGES: false,             // false = run with --security-opt no-new-privileges
    DEPLOY_STATE_DIR    : '',                       // where the previous-version state is kept on the deploy host ('' = $HOME/.devsecops-deploy)

    // ---- registry: ecr | generic | none ----
    REGISTRY_TYPE       : 'ecr',
    AWS_REGION          : 'YOUR_AWS_REGION',        // e.g. eu-west-1
    ECR_REGISTRY        : '',                       // '' = derived from the AWS account of the credentials / IAM role
    ECR_REPOSITORY      : '',                       // empty = DOCKER_IMAGE
    ECR_CREATE_REPO     : false,                    // true = create the repository (scan on push + immutable tags) when missing
    AWS_CREDENTIALS_ID  : '',                       // Jenkins "AWS Credentials". '' = use the agent's IAM role (recommended)
    REGISTRY_URL        : '',                       // generic registry host, e.g. registry.example.com
    REGISTRY_REPOSITORY : '',                       // generic registry repository path. Empty = DOCKER_IMAGE
    REGISTRY_CREDENTIALS_ID: 'registry-credentials',// Jenkins "Username with password" (generic registry only)

    // ======================= 11. IIS DEPLOYMENT (Windows) =======================
    // WHERE TO DEPLOY - give the site name, the path, or both:
    //   IIS_SITE_NAME only -> path + pool are READ FROM IIS automatically (use this when the company did not tell you the path)
    //   IIS_SITE_PATH only -> the site / application / pool that owns that path is looked up in IIS
    //   both               -> cross-checked; a mismatch stops the pipeline (wrong-folder protection)
    // Not sure what exists on the server? Run the job with ACTION = discover-iis: it lists sites, paths and pools.
    IIS_SITE_NAME       : '',                       // site name exactly as shown in IIS Manager
    IIS_APPLICATION     : '',                       // optional virtual application under the site ('' = the site root)
    IIS_APP_POOL        : '',                       // optional: read from IIS when empty (if set, it must match IIS)
    IIS_SITE_PATH       : '',                       // optional: read from IIS when empty. Example: 'D:\\Sites\\MyApp'
    IIS_ALLOWED_PATH_PREFIXES: '',                  // required ONLY when IIS_SITE_PATH is set: it must be inside one of these, e.g. 'D:\\Sites'
    IIS_BACKUP_ROOT     : '',                       // outside IIS_SITE_PATH, e.g. 'D:\\Backups\\IIS'  ->  <root>\<APP_NAME>\yyyy-MM-dd_HHmmss
    IIS_BACKUP_KEEP     : 10,
    IIS_PRESERVE_PATHS  : 'logs,App_Data,uploads',  // never overwritten / deleted / backed up. Add web.config to keep the server's copy
    IIS_STRATEGY        : 'app_offline',            // app_offline (default, pool keeps running) | stop_pool (stop only THIS pool while copying)
    IIS_PURGE           : true,                     // true = mirror (remove files that are not in the new build); false = copy over only
    IIS_CREATE_PATH     : false,                    // true only for a first deployment into a new folder
    IIS_REQUIRE_WEB_CONFIG: true,
    IIS_GRANT_PERMISSIONS: false,                   // true = grant the app pool identity read (and modify on IIS_WRITABLE_PATHS)
    IIS_WRITABLE_PATHS  : 'logs',
    IIS_STOP_TIMEOUT_SEC: 60,                       // stop_pool strategy: seconds to wait until the pool is stopped

    // ======================= 12. HEALTH CHECK =======================
    HEALTH_CHECK_URL    : '',                       // docker: empty = http://localhost:<DOCKER_HOST_PORT>/   iis: required
    HEALTH_CHECK_RETRIES: 10,
    HEALTH_CHECK_DELAY  : 6,                        // seconds between attempts
    HEALTH_CHECK_TIMEOUT: 15,                       // seconds per request
    HEALTH_EXPECTED_STATUS: '200',                  // comma separated, e.g. '200,204'
    HEALTH_SKIP_TLS_VERIFY: false,                  // internal self-signed certificates only
    HEALTH_CRED_ID      : '',                       // optional "Username with password" for HTTP basic auth

    // ======================= 13. ROLLBACK & PRODUCTION PROTECTION =======================
    ROLLBACK_ENABLED    : true,
    PRODUCTION_APPROVAL : true,                     // manual approval before anything is deployed to production
    APPROVERS           : '',                       // comma separated Jenkins users/groups allowed to approve ('' = anyone who can build)
    APPROVAL_TIMEOUT_MIN: 60,
    PRODUCTION_REQUIRE_USER: true,                  // production runs must be started by a person (never by a webhook / SCM poll)
    PRODUCTION_BRANCHES : 'main,master',            // only these branches may be deployed to production ('' = any)

    // ======================= 14. AGENTS (Jenkins labels) =======================
    AGENT_BUILD         : 'linux-docker',           // CI + security scans
    AGENT_DOCKER        : 'linux-docker',           // docker build / scan / deploy (can differ per environment, see ENV_OVERRIDES)
    AGENT_IIS           : 'windows-iis',            // dotnet publish + IIS deployment

    // ======================= 15. NOTIFICATIONS (all optional) =======================
    NOTIFY_ON           : 'SUCCESS,FAILURE,UNSTABLE,ABORTED', // which results send a notification, e.g. 'FAILURE,UNSTABLE' = only problems
    NOTIFY_EMAIL        : '',                       // comma separated recipients; needs SMTP configured in Jenkins (Mailer plugin)
    NOTIFY_EMAIL_CC     : '',                       // optional
    NOTIFY_EMAIL_FROM   : '',                       // optional sender address ('' = Jenkins default)
    NOTIFY_SLACK_CRED_ID: '',                       // "Secret text" credential holding a Slack incoming-webhook URL
    NOTIFY_TEAMS_CRED_ID: '',                       // "Secret text" credential holding a Teams incoming-webhook URL

    // ======================= 16. PIPELINE =======================
    TIMEOUT_MINUTES     : 90,
    KEEP_BUILDS         : 30,
    CLEAN_WORKSPACE     : true,

    // ======================= 17. PER-ENVIRONMENT OVERRIDES =======================
    // Any key above can be overridden per environment. Example:
    //   staging    : [ DOCKER_HOST_PORT: '8081', HEALTH_CHECK_URL: 'http://staging-host:8081/health' ],
    //   production : [ AGENT_DOCKER: 'linux-docker-prod', AWS_CREDENTIALS_ID: 'aws-prod', IIS_SITE_NAME: 'MyApp-Prod' ]
    ENV_OVERRIDES       : [
        dev        : [:],
        staging    : [:],
        production : [:]
    ]
]

// Runtime state (filled while the pipeline runs - do not edit)
@Field Map EFF = [:]        // effective configuration = CFG + overrides of the selected environment
@Field Map FLAGS = [:]      // what is enabled in THIS run (config switch AND job parameter)
@Field Map RESULTS = [:]    // security scan results used by the security gate

// -----------------------------------------------------------------------------
//  PIPELINE  -  do not edit below this line
// -----------------------------------------------------------------------------
pipeline {
    agent none

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
        timeout(time: CFG.TIMEOUT_MINUTES, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: CFG.KEEP_BUILDS.toString()))
    }

    // GitHub / Bitbucket webhook (token in a Jenkins credential) + optional low-frequency SCM polling as fallback.
    // URL: https://<jenkins>/generic-webhook-trigger/invoke?token=<token>
    triggers {
        GenericTrigger(
            genericVariables: [
                [key: 'WH_GITHUB_REF',      value: '$.ref',                     expressionType: 'JSONPath', defaultValue: ''],  // GitHub push
                [key: 'WH_BB_CLOUD_BRANCH', value: '$.push.changes[0].new.name', expressionType: 'JSONPath', defaultValue: ''],  // Bitbucket Cloud push
                [key: 'WH_BB_SERVER_REF',   value: '$.changes[0].ref.id',        expressionType: 'JSONPath', defaultValue: '']   // Bitbucket Server / DC push
            ],
            tokenCredentialId: CFG.WEBHOOK_TOKEN_CRED_ID,
            causeString: 'Webhook push to ' + CFG.BRANCH,
            printContributedVariables: false,
            printPostContent: false,
            silentResponse: false,
            shouldNotFlattern: true,
            regexpFilterText: '$WH_GITHUB_REF$WH_BB_CLOUD_BRANCH$WH_BB_SERVER_REF',
            regexpFilterExpression: '^(refs/heads/)?\\Q' + CFG.BRANCH + '\\E$'
        )
        pollSCM(CFG.POLL_SCM_CRON)
    }

    parameters {
        choice(name: 'ACTION', choices: ['deploy', 'rollback', 'discover-iis'],
               description: 'deploy = full pipeline.  rollback = restore the previous version (no build, no scans).  discover-iis = list IIS sites, paths and pools on the Windows agent (read-only).')
        choice(name: 'DEPLOY_TYPE',
               choices: (CFG.DEPLOY_TYPE == 'iis') ? ['iis', 'docker', 'none'] : ((CFG.DEPLOY_TYPE == 'none') ? ['none', 'docker', 'iis'] : ['docker', 'iis', 'none']),
               description: 'docker = container deployment, iis = .NET to Windows IIS, none = build + security checks only.')
        choice(name: 'ENVIRONMENT',
               choices: (CFG.DEFAULT_ENVIRONMENT == 'staging') ? ['staging', 'dev', 'production'] : ['dev', 'staging', 'production'],
               description: 'Target environment. Production needs CONFIRM_PRODUCTION and a manual approval.')
        booleanParam(name: 'RUN_TESTS',      defaultValue: true, description: 'Run the tests')
        booleanParam(name: 'RUN_SONARQUBE',  defaultValue: true, description: 'Run SonarQube analysis (only if ENABLE_SONARQUBE is true in the config)')
        booleanParam(name: 'RUN_OWASP',      defaultValue: true, description: 'Run OWASP Dependency-Check (only if ENABLE_OWASP is true in the config)')
        booleanParam(name: 'RUN_TRIVY',      defaultValue: true, description: 'Run Trivy scans (only if ENABLE_TRIVY is true in the config)')
        booleanParam(name: 'CONFIRM_PRODUCTION', defaultValue: false, description: 'REQUIRED to deploy or roll back in production. Leave unticked for everything else.')
    }

    environment {
        DOTNET_CLI_TELEMETRY_OPTOUT       = '1'
        DOTNET_NOLOGO                     = '1'
        DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
        DOTNET_CLI_UI_LANGUAGE            = 'en'
    }

    stages {

        // ---------------------------------------------------------------------
        stage('Initialize') {
            steps {
                script { initialize() }
            }
        }

        // ================== CI + SECURITY  (Linux agent) ==================
        stage('CI and Security (Linux agent)') {
            when { beforeAgent true; expression { params.ACTION == 'deploy' } }
            agent { label EFF.AGENT_BUILD }
            stages {

                stage('Checkout') {
                    steps { script { checkoutSources() } }
                }

                stage('Detect Application Type') {
                    steps {
                        script {
                            env.APP_TYPE_RESOLVED = sh(returnStdout: true, script: "bash ${env.SCRIPTS_DIR}/detect-app-type.sh").trim()
                            echo "Application type: ${env.APP_TYPE_RESOLVED}"
                            if (params.DEPLOY_TYPE == 'iis' && env.APP_TYPE_RESOLVED != 'dotnet') {
                                error "DEPLOY_TYPE=iis needs a .NET application, but the application type is '${env.APP_TYPE_RESOLVED}'. Set APP_TYPE in the CFG block."
                            }
                        }
                    }
                }

                stage('Restore Dependencies') {
                    when { expression { phaseApplies('restore') } }
                    steps { sh "bash ${env.SCRIPTS_DIR}/ci-run.sh restore" }
                }

                stage('Build') {
                    when { expression { phaseApplies('build') && !sonarDotnetMode() } }
                    steps { sh "bash ${env.SCRIPTS_DIR}/ci-run.sh build" }
                }

                stage('Test') {
                    when { expression { FLAGS.TESTS && phaseApplies('test') && !sonarDotnetMode() } }
                    steps { sh "bash ${env.SCRIPTS_DIR}/ci-run.sh test" }
                }

                // .NET + SonarQube must be: sonarscanner begin -> build (+ test) -> sonarscanner end
                stage('Build, Test and SonarQube (.NET)') {
                    when { expression { sonarDotnetMode() } }
                    steps { script { runSonarDotnet() } }
                }

                stage('SonarQube Analysis') {
                    when { expression { FLAGS.SONAR && !sonarDotnetMode() } }
                    steps { script { runSonarGeneric() } }
                }

                stage('OWASP Dependency-Check') {
                    when { expression { FLAGS.OWASP } }
                    steps { script { runOwasp() } }
                }

                stage('Trivy Filesystem Scan') {
                    when { expression { FLAGS.TRIVY_FS } }
                    steps { script { runTrivyFs() } }
                }

                stage('Security Gate') {
                    steps { script { securityGate() } }
                }

                stage('Package Source') {
                    when { expression { params.DEPLOY_TYPE != 'none' } }
                    steps {
                        stash name: 'source', includes: '**', allowEmpty: false, useDefaultExcludes: true,
                              excludes: 'reports/**,.sonarqube/**,.scannerwork/**,node_modules/**,.venv/**,**/obj/**,**/bin/Debug/**,**/bin/Release/**,TestResults/**'
                    }
                }
            }
            post {
                always {
                    script { collectSonarInfo() }
                    archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
                }
                cleanup {
                    script { if (flag(EFF.CLEAN_WORKSPACE, true)) { deleteDir() } }
                }
            }
        }

        // ================== PRODUCTION APPROVAL (no executor is held) ==================
        stage('Production Approval') {
            when { expression { params.ACTION == 'deploy' && params.DEPLOY_TYPE != 'none' && params.ENVIRONMENT == 'production' && flag(EFF.PRODUCTION_APPROVAL, true) } }
            steps {
                script {
                    timeout(time: EFF.APPROVAL_TIMEOUT_MIN as int, unit: 'MINUTES') {
                        input message: "Deploy ${EFF.APP_NAME} build #${env.BUILD_NUMBER} (${env.GIT_COMMIT_SHORT}) to PRODUCTION using ${params.DEPLOY_TYPE}?",
                              ok: 'Deploy to production',
                              submitter: (EFF.APPROVERS ?: '')
                    }
                }
            }
        }

        // ================== DOCKER DEPLOYMENT (Linux agent) ==================
        stage('Deploy - Docker (Linux agent)') {
            when { beforeAgent true; expression { params.ACTION == 'deploy' && params.DEPLOY_TYPE == 'docker' } }
            agent { label EFF.AGENT_DOCKER }
            stages {

                stage('Docker - Prepare Workspace') {
                    steps { script { unstashSource() } }
                }

                stage('Docker Build') {
                    steps {
                        script {
                            withAws { sh "bash ${env.SCRIPTS_DIR}/docker-build.sh" }
                            env.IMAGE_REF  = readFile('reports/docker/image-ref.txt').trim()
                            env.IMAGE_REPO = readFile('reports/docker/image-repo.txt').trim()
                            echo "Image: ${env.IMAGE_REF}"
                        }
                    }
                }

                stage('Image Scan (Trivy)') {
                    when { expression { FLAGS.TRIVY_IMAGE } }
                    steps { script { scanImage() } }
                }

                stage('Registry Push') {
                    when { expression { EFF.REGISTRY_TYPE != 'none' } }
                    steps { script { withRegistry { sh "bash ${env.SCRIPTS_DIR}/docker-push.sh" } } }
                }

                stage('Deploy Container') {
                    steps {
                        script {
                            env.DOCKER_DEPLOY_TOUCHED = 'true'      // from here on a failure triggers the rollback
                            withRegistry { withRuntimeEnvFile { sh "bash ${env.SCRIPTS_DIR}/docker-deploy.sh deploy" } }
                        }
                    }
                }

                stage('Docker - Health Check') {
                    steps {
                        script {
                            withHealthCreds { sh "bash ${env.SCRIPTS_DIR}/health-check.sh" }
                            sh "bash ${env.SCRIPTS_DIR}/docker-deploy.sh finalize"
                            echo 'Docker deployment healthy and finalized.'
                        }
                    }
                }
            }
            post {
                failure {
                    script { dockerRollbackIfNeeded() }
                }
                cleanup {
                    script { dockerCleanup() }
                }
            }
        }

        // ================== IIS DEPLOYMENT (Windows agent) ==================
        stage('Deploy - IIS (Windows agent)') {
            when { beforeAgent true; expression { params.ACTION == 'deploy' && params.DEPLOY_TYPE == 'iis' } }
            agent { label EFF.AGENT_IIS }
            stages {

                stage('IIS - Prepare Workspace') {
                    steps { script { unstashSource() } }
                }

                stage('dotnet publish') {
                    steps { script { psFile('dotnet-publish.ps1') } }
                }

                stage('Backup Current IIS App') {
                    steps { script { psFile('iis-deploy.ps1', '-Phase Backup') } }
                }

                stage('Deploy Files') {
                    steps {
                        script {
                            env.IIS_DEPLOY_TOUCHED = 'true'         // from here on a failure triggers the rollback
                            psFile('iis-deploy.ps1', '-Phase Deploy')
                        }
                    }
                }

                stage('Recycle App Pool') {
                    steps { script { psFile('iis-deploy.ps1', '-Phase Recycle') } }
                }

                stage('IIS - Health Check') {
                    steps { script { withHealthCreds { psFile('health-check.ps1') } } }
                }
            }
            post {
                failure {
                    script { iisRollbackIfNeeded() }
                }
                cleanup {
                    script { if (flag(EFF.CLEAN_WORKSPACE, true)) { deleteDir() } }
                }
            }
        }

        // ================== MANUAL ROLLBACK (ACTION = rollback) ==================
        stage('Rollback - Docker') {
            when { beforeAgent true; expression { params.ACTION == 'rollback' && params.DEPLOY_TYPE == 'docker' } }
            agent { label EFF.AGENT_DOCKER }
            steps {
                script {
                    checkoutSources()
                    withRegistry { sh "bash ${env.SCRIPTS_DIR}/docker-rollback.sh manual" }
                    withHealthCreds { sh "bash ${env.SCRIPTS_DIR}/health-check.sh" }
                    echo 'ROLLBACK SUCCESSFUL: the previous version is running and healthy.'
                }
            }
            post {
                cleanup { script { if (flag(EFF.CLEAN_WORKSPACE, true)) { deleteDir() } } }
            }
        }

        stage('Rollback - IIS') {
            when { beforeAgent true; expression { params.ACTION == 'rollback' && params.DEPLOY_TYPE == 'iis' } }
            agent { label EFF.AGENT_IIS }
            steps {
                script {
                    checkoutSources()
                    psFile('iis-rollback.ps1')
                    withHealthCreds { psFile('health-check.ps1') }
                    echo 'ROLLBACK SUCCESSFUL: the previous version is running and healthy.'
                }
            }
            post {
                cleanup { script { if (flag(EFF.CLEAN_WORKSPACE, true)) { deleteDir() } } }
            }
        }

        // ================== IIS DISCOVERY (ACTION = discover-iis, read-only) ==================
        stage('IIS Discovery (Windows agent)') {
            when { beforeAgent true; expression { params.ACTION == 'discover-iis' } }
            agent { label EFF.AGENT_IIS }
            steps {
                script {
                    checkoutSources()
                    psFile('iis-discover.ps1')
                }
            }
            post {
                cleanup { script { if (flag(EFF.CLEAN_WORKSPACE, true)) { deleteDir() } } }
            }
        }
    }

    post {
        success  { script { notifyAll('SUCCESS') } }
        unstable { script { notifyAll('UNSTABLE') } }
        failure  { script { notifyAll('FAILURE') } }
        aborted  { script { notifyAll('ABORTED') } }
        always   { script { echo finalBanner() } }
    }
}

// =============================================================================
//  Initialization, validation, production protection
// =============================================================================
def initialize() {
    EFF = [:]
    EFF.putAll(CFG)
    Map overrides = (CFG.ENV_OVERRIDES ?: [:])[params.ENVIRONMENT] ?: [:]
    EFF.putAll(overrides)
    EFF.remove('ENV_OVERRIDES')

    // defaults derived from other values
    EFF.DOCKER_IMAGE        = EFF.DOCKER_IMAGE ?: EFF.APP_NAME
    EFF.DOCKER_CONTAINER    = EFF.DOCKER_CONTAINER ?: EFF.APP_NAME
    EFF.ECR_REPOSITORY      = EFF.ECR_REPOSITORY ?: EFF.DOCKER_IMAGE
    EFF.SONAR_PROJECT_KEY   = EFF.SONAR_PROJECT_KEY ?: EFF.APP_NAME
    EFF.SONAR_PROJECT_NAME  = EFF.SONAR_PROJECT_NAME ?: EFF.APP_NAME
    if (params.DEPLOY_TYPE == 'docker' && !EFF.HEALTH_CHECK_URL && EFF.DOCKER_HOST_PORT) {
        EFF.HEALTH_CHECK_URL = "http://localhost:${EFF.DOCKER_HOST_PORT}/".toString()
    }

    List problems = configProblems()
    if (problems) {
        error "CONFIGURATION ERROR - fix the CFG block of the Jenkinsfile:\n - " + problems.join('\n - ')
    }
    guardProduction()

    String fsMode = EFF.TRIVY_FS_SCAN.toString()
    FLAGS = [:]
    FLAGS.TESTS       = flag(EFF.ENABLE_TESTS, true)     && flag(params.RUN_TESTS, true)
    FLAGS.SONAR       = flag(EFF.ENABLE_SONARQUBE, true) && flag(params.RUN_SONARQUBE, true)
    FLAGS.OWASP       = flag(EFF.ENABLE_OWASP, true)     && flag(params.RUN_OWASP, true)
    FLAGS.TRIVY       = flag(EFF.ENABLE_TRIVY, true)     && flag(params.RUN_TRIVY, true)
    FLAGS.TRIVY_FS    = FLAGS.TRIVY && (fsMode == 'true' || (fsMode == 'auto' && params.DEPLOY_TYPE != 'docker'))
    FLAGS.TRIVY_IMAGE = FLAGS.TRIVY && params.DEPLOY_TYPE == 'docker'

    // export every setting to the shell / PowerShell scripts (as environment variables)
    for (def entry : EFF.entrySet()) {
        if (!(entry.value instanceof Map)) { env[entry.key] = (entry.value == null) ? '' : entry.value.toString() }
    }
    env.DEPLOY_ENV            = params.ENVIRONMENT
    env.DEPLOY_TYPE           = params.DEPLOY_TYPE
    env.DOCKER_DEPLOY_TOUCHED = 'false'
    env.IIS_DEPLOY_TOUCHED    = 'false'
    env.PUBLISH_DIR           = 'publish'
    env.REPORTS_DIR           = 'reports'
    currentBuild.displayName  = "#${env.BUILD_NUMBER} ${EFF.APP_NAME} ${params.ENVIRONMENT}"

    String agents = (params.DEPLOY_TYPE == 'docker') ? EFF.AGENT_DOCKER : ((params.DEPLOY_TYPE == 'iis') ? EFF.AGENT_IIS : '-')
    echo """
==================== PIPELINE PLAN ====================
 Application   : ${EFF.APP_NAME}  (type: ${EFF.APP_TYPE})
 Action        : ${params.ACTION}
 Environment   : ${params.ENVIRONMENT}
 Deploy type   : ${params.DEPLOY_TYPE}
 Agents        : build=${EFF.AGENT_BUILD}   deploy=${agents}
 Source        : ${EFF.USE_JOB_SCM ? '(job SCM)' : EFF.REPO_URL} @ ${EFF.BRANCH}
 Stages enabled: tests=${FLAGS.TESTS} sonarqube=${FLAGS.SONAR} owasp=${FLAGS.OWASP} trivy-fs=${FLAGS.TRIVY_FS} trivy-image=${FLAGS.TRIVY_IMAGE}
 Security gate : ${EFF.SECURITY_GATE}   rollback: ${EFF.ROLLBACK_ENABLED}
=======================================================
"""
}

def configProblems() {
    List p = []
    List required = ['APP_NAME', 'AGENT_BUILD', 'WEBHOOK_TOKEN_CRED_ID']
    if (!EFF.USE_JOB_SCM) { required << 'REPO_URL' << 'BRANCH' }
    String dt = params.DEPLOY_TYPE
    if (params.ACTION == 'discover-iis') { dt = 'discover'; required << 'AGENT_IIS' }

    if (params.ACTION == 'rollback' && dt == 'none') { p << 'ACTION=rollback needs DEPLOY_TYPE docker or iis.' }
    if (dt == 'docker') {
        required << 'AGENT_DOCKER' << 'DOCKER_IMAGE' << 'DOCKER_CONTAINER' << 'HEALTH_CHECK_URL'
        if (EFF.REGISTRY_TYPE == 'ecr') { required << 'AWS_REGION' }
        else if (EFF.REGISTRY_TYPE == 'generic') { required << 'REGISTRY_URL' << 'REGISTRY_CREDENTIALS_ID' }
        else if (EFF.REGISTRY_TYPE != 'none') { p << "REGISTRY_TYPE must be ecr, generic or none (got '${EFF.REGISTRY_TYPE}')." }
        if (EFF.DOCKER_HOST_PORT && !EFF.DOCKER_CONTAINER_PORT) { p << 'DOCKER_CONTAINER_PORT is required when DOCKER_HOST_PORT is set.' }
    }
    if (dt == 'iis') {
        required << 'AGENT_IIS' << 'DOTNET_PROJECT' << 'IIS_BACKUP_ROOT' << 'HEALTH_CHECK_URL'
        if (!EFF.IIS_SITE_NAME?.toString()?.trim() && !EFF.IIS_SITE_PATH?.toString()?.trim()) {
            p << 'IIS target is not set: give IIS_SITE_NAME (path and pool are then read from IIS) or IIS_SITE_PATH. Run ACTION=discover-iis to see what exists on the server.'
        }
        if (EFF.IIS_SITE_PATH?.toString()?.trim() && !EFF.IIS_ALLOWED_PATH_PREFIXES?.toString()?.trim()) {
            p << 'IIS_ALLOWED_PATH_PREFIXES is required when IIS_SITE_PATH is set (e.g. the folder that contains all your sites).'
        }
        if (!(EFF.IIS_STRATEGY in ['app_offline', 'stop_pool'])) { p << "IIS_STRATEGY must be app_offline or stop_pool (got '${EFF.IIS_STRATEGY}')." }
    }
    for (String k : required) {
        String v = (EFF[k] == null) ? '' : EFF[k].toString().trim()
        if (v.isEmpty() || v == 'CHANGE_ME' || v.startsWith('YOUR_')) { p << "${k} is not set (value: '${v}')." }
    }

    if (!(EFF.APP_NAME.toString() ==~ /^[A-Za-z0-9._-]+$/)) { p << 'APP_NAME may contain only letters, digits, dot, underscore and dash.' }
    if (!(EFF.APP_TYPE in ['auto', 'dotnet', 'node', 'python', 'docker', 'generic'])) { p << "APP_TYPE '${EFF.APP_TYPE}' is not valid." }
    for (String k : ['SONAR_POLICY', 'OWASP_POLICY', 'TRIVY_POLICY']) {
        if (!(EFF[k] in ['fail', 'unstable', 'ignore'])) { p << "${k} must be fail, unstable or ignore (got '${EFF[k]}')." }
    }
    if (!(EFF.SECURITY_GATE in ['enforce', 'warn', 'off'])) { p << "SECURITY_GATE must be enforce, warn or off (got '${EFF.SECURITY_GATE}')." }
    if (EFF.HEALTH_CHECK_URL && !(EFF.HEALTH_CHECK_URL.toString() ==~ /^https?:\/\/.+/)) { p << 'HEALTH_CHECK_URL must start with http:// or https://' }
    for (String k : ['DOTNET_SOLUTION', 'DOTNET_PROJECT', 'DOTNET_TEST_PROJECT', 'DOCKERFILE_PATH', 'DOCKER_CONTEXT']) {
        String v = (EFF[k] ?: '').toString()
        if (v && (v.startsWith('/') || v.startsWith('\\') || v.indexOf(':') == 1 || v.contains('..'))) {
            p << "${k} must be a path RELATIVE to the repository root (got '${v}')."
        }
    }
    return p
}

def guardProduction() {
    if (params.ENVIRONMENT != 'production' || params.DEPLOY_TYPE == 'none' || params.ACTION == 'discover-iis') { return }
    if (!flag(params.CONFIRM_PRODUCTION, false)) {
        error 'PRODUCTION SAFETY: tick CONFIRM_PRODUCTION to deploy or roll back in production. Nothing was changed.'
    }
    if (flag(EFF.PRODUCTION_REQUIRE_USER, true) && !currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')) {
        error 'PRODUCTION SAFETY: production runs must be started manually by a person (webhook / SCM-triggered builds can never deploy to production).'
    }
    String branch = env.BRANCH_NAME ?: EFF.BRANCH
    if (EFF.PRODUCTION_BRANCHES) {
        boolean allowed = false
        for (String b : EFF.PRODUCTION_BRANCHES.toString().split(',')) {
            if (b.trim() == branch) { allowed = true }
        }
        if (!allowed) { error "PRODUCTION SAFETY: branch '${branch}' may not be deployed to production (allowed: ${EFF.PRODUCTION_BRANCHES})." }
    }
}

// =============================================================================
//  Small helpers
// =============================================================================
def flag(Object value, boolean dflt) {
    return (value == null) ? dflt : value.toString().toBoolean()
}

def phaseApplies(String phase) {
    String custom = (phase == 'restore') ? EFF.INSTALL_COMMAND : ((phase == 'build') ? EFF.BUILD_COMMAND : EFF.TEST_COMMAND)
    if (custom?.trim()) { return true }
    return env.APP_TYPE_RESOLVED in ['dotnet', 'node', 'python']
}

def sonarDotnetMode() {
    return FLAGS.SONAR && env.APP_TYPE_RESOLVED == 'dotnet' && !(EFF.BUILD_COMMAND?.trim())
}

def checkoutGit(String url, String branch, String credentialsId) {
    Map remote = [url: url]
    if (credentialsId) { remote.credentialsId = credentialsId }
    return checkout([
        $class: 'GitSCM',
        branches: [[name: ('*/' + branch).toString()]],
        userRemoteConfigs: [remote],
        extensions: [
            [$class: 'CleanBeforeCheckout'],
            [$class: 'CloneOption', noTags: true, shallow: false, timeout: 20]
        ]
    ])
}

def checkoutSources() {
    def scmVars = EFF.USE_JOB_SCM ? checkout(scm) : checkoutGit(EFF.REPO_URL, EFF.BRANCH, EFF.GIT_CREDENTIALS_ID)
    env.GIT_COMMIT_FULL  = scmVars.GIT_COMMIT ?: ''
    env.GIT_COMMIT_SHORT = (scmVars.GIT_COMMIT ?: 'unknown').take(7)
    env.IMAGE_TAG        = "${env.BUILD_NUMBER}-${env.GIT_COMMIT_SHORT}".toString()     // immutable tag
    currentBuild.description = "${EFF.BRANCH} @ ${env.GIT_COMMIT_SHORT}"
    echo "Checked out ${EFF.BRANCH} at ${env.GIT_COMMIT_FULL}"

    if (EFF.SCRIPTS_REPO_URL) {                               // checked out AFTER the app so that the clean step cannot remove it
        dir('.framework') { checkoutGit(EFF.SCRIPTS_REPO_URL, EFF.SCRIPTS_REPO_BRANCH ?: 'main', EFF.SCRIPTS_REPO_CRED_ID) }
        env.SCRIPTS_DIR = '.framework/scripts'
    } else {
        env.SCRIPTS_DIR = 'scripts'
    }
    if (!fileExists(env.SCRIPTS_DIR + '/lib/common.sh')) {
        error "The pipeline scripts were not found in '${env.SCRIPTS_DIR}'. Copy the scripts/ folder into your repository or set SCRIPTS_REPO_URL."
    }
}

def unstashSource() {
    deleteDir()
    unstash 'source'
    if (!fileExists(env.SCRIPTS_DIR + '/lib/common.sh')) { error "Scripts missing after unstash ('${env.SCRIPTS_DIR}')." }
}

def psFile(String file, String args = '') {
    String path = "${env.SCRIPTS_DIR}/${file}"
    powershell(script: "\$ErrorActionPreference = 'Stop'\n& './${path}' ${args}\nif (\$LASTEXITCODE -ne 0) { exit \$LASTEXITCODE }")
}

// ---- credential wrappers: secrets exist only inside these blocks and are masked in the log ----
def withAws(Closure body) {
    if (EFF.AWS_CREDENTIALS_ID) {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: EFF.AWS_CREDENTIALS_ID,
                          accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) { body() }
    } else {
        body()          // no credential configured: the agent's IAM role / profile is used
    }
}

def withRegistry(Closure body) {
    if (EFF.REGISTRY_TYPE == 'generic' && EFF.REGISTRY_CREDENTIALS_ID) {
        withCredentials([usernamePassword(credentialsId: EFF.REGISTRY_CREDENTIALS_ID, usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) { body() }
    } else if (EFF.REGISTRY_TYPE == 'ecr') {
        withAws { body() }
    } else {
        body()
    }
}

def withRuntimeEnvFile(Closure body) {
    if (EFF.DOCKER_ENV_FILE_CRED_ID) {
        withCredentials([file(credentialsId: EFF.DOCKER_ENV_FILE_CRED_ID, variable: 'DOCKER_ENV_FILE')]) { body() }
    } else {
        body()
    }
}

def withHealthCreds(Closure body) {
    if (EFF.HEALTH_CRED_ID) {
        withCredentials([usernamePassword(credentialsId: EFF.HEALTH_CRED_ID, usernameVariable: 'HC_USER', passwordVariable: 'HC_PASS')]) { body() }
    } else {
        body()
    }
}

def withNvdKey(Closure body) {
    if (EFF.OWASP_NVD_API_KEY_CRED_ID) {
        withCredentials([string(credentialsId: EFF.OWASP_NVD_API_KEY_CRED_ID, variable: 'NVD_API_KEY')]) { body() }
    } else {
        body()
    }
}

// =============================================================================
//  SonarQube / OWASP / Trivy  +  Security Gate
// =============================================================================
def record(String name, String status, String detail) {
    RESULTS[name] = [status: status, detail: detail]
}

def readSummary(String name) {
    String path = "reports/summary/${name}.env"
    return fileExists(path) ? readFile(path).trim().replace('\n', ', ') : ''
}

def runSonarDotnet() {
    withSonarQubeEnv(EFF.SONAR_SERVER_NAME) {
        withEnv(['SONAR_RUN_TESTS=' + FLAGS.TESTS]) {
            sh "bash ${env.SCRIPTS_DIR}/sonar-dotnet.sh"
        }
    }
    sonarQualityGate()
}

def runSonarGeneric() {
    withSonarQubeEnv(EFF.SONAR_SERVER_NAME) {
        if (EFF.SONAR_SCANNER_TOOL) {
            String home = tool(name: EFF.SONAR_SCANNER_TOOL, type: 'hudson.plugins.sonar.SonarRunnerInstallation')
            withEnv(['SONAR_SCANNER_HOME=' + home]) { sh "bash ${env.SCRIPTS_DIR}/sonar-generic.sh" }
        } else {
            sh "bash ${env.SCRIPTS_DIR}/sonar-generic.sh"
        }
    }
    sonarQualityGate()
}

def sonarQualityGate() {
    if (!flag(EFF.SONAR_QUALITY_GATE, true)) {
        record('sonarqube', 'PASS', 'analysis uploaded (quality gate check disabled)')
        return
    }
    try {
        timeout(time: EFF.SONAR_QG_TIMEOUT_MIN as int, unit: 'MINUTES') {
            def qg = waitForQualityGate()
            if (qg.status == 'OK' || qg.status == 'WARN') {
                record('sonarqube', 'PASS', "quality gate ${qg.status}")
            } else {
                record('sonarqube', 'FAIL', "quality gate ${qg.status}")
            }
        }
    } catch (err) {
        record('sonarqube', 'FAIL', "quality gate result unavailable: ${err.message} (is the SonarQube -> Jenkins webhook configured?)")
    }
}

def collectSonarInfo() {
    if (fileExists('.sonarqube/out/.sonar/report-task.txt')) {
        sh 'mkdir -p reports/sonar && cp .sonarqube/out/.sonar/report-task.txt reports/sonar/report-task.txt'
    } else if (fileExists('.scannerwork/report-task.txt')) {
        sh 'mkdir -p reports/sonar && cp .scannerwork/report-task.txt reports/sonar/report-task.txt'
    }
}

def handleScan(String name, String summary, int rc, String label, String doc) {
    if (rc == 0) {
        record(name, 'PASS', readSummary(summary))
    } else if (rc == 10) {
        error "${label} could not run (tool missing or failed). See the log above and ${doc}. Scans are never skipped silently - set the matching ENABLE_* switch to false if this application does not use it."
    } else {
        record(name, 'FAIL', readSummary(summary) ?: "exit code ${rc}")
    }
}

def runOwasp() {
    Map out = [rc: 0]
    withNvdKey {
        out.rc = sh(script: "bash ${env.SCRIPTS_DIR}/owasp-scan.sh", returnStatus: true)
    }
    handleScan('owasp', 'owasp', out.rc as int, 'OWASP Dependency-Check', 'docs/owasp-setup.md')
}

def runTrivyFs() {
    int rc = sh(script: "bash ${env.SCRIPTS_DIR}/trivy-scan.sh fs .", returnStatus: true)
    handleScan('trivy', 'trivy-fs', rc, 'Trivy filesystem scan', 'docs/trivy-setup.md')
}

def scanImage() {
    int rc = sh(script: "bash ${env.SCRIPTS_DIR}/trivy-scan.sh image ${env.IMAGE_REF}", returnStatus: true)
    if (rc == 0) {
        echo "Trivy image scan passed (${readSummary('trivy-image')})"
    } else if (rc == 10) {
        error 'Trivy could not scan the image (tool missing or failed). See docs/trivy-setup.md. Nothing was pushed or deployed.'
    } else {
        enforcePolicy('trivy-image', EFF.TRIVY_POLICY, readSummary('trivy-image') ?: "exit code ${rc}")
    }
}

def policyFor(String name) {
    return [sonarqube: EFF.SONAR_POLICY, owasp: EFF.OWASP_POLICY, trivy: EFF.TRIVY_POLICY][name] ?: 'fail'
}

def enforcePolicy(String name, String policy, String detail) {
    if (EFF.SECURITY_GATE == 'off') {
        echo "[security gate OFF] ${name}: ${detail}"
        return
    }
    String effective = (EFF.SECURITY_GATE == 'warn' && policy == 'fail') ? 'unstable' : policy
    if (effective == 'fail') {
        error "SECURITY GATE FAILED: ${name} - ${detail}. Deployment blocked."
    } else if (effective == 'unstable') {
        unstable "SECURITY GATE WARNING: ${name} - ${detail} (build marked UNSTABLE, continuing)"
    } else {
        echo "WARNING: ${name} - ${detail} (policy: ignore)"
    }
}

def securityGate() {
    echo '================== SECURITY GATE =================='
    List failed = []
    for (String n : ['sonarqube', 'owasp', 'trivy']) {
        Map r = RESULTS[n] ?: [status: 'SKIPPED', detail: 'not executed in this run']
        String icon = (r.status == 'PASS') ? '✓' : ((r.status == 'FAIL') ? '✗' : '-')
        echo " ${icon} ${n.padRight(10)} ${r.status}   ${r.detail}"
        if (r.status == 'FAIL') { failed << n }
    }
    if (EFF.SECURITY_GATE == 'off') {
        echo 'Security gate is OFF (SECURITY_GATE=off): results are informational only.'
        return
    }
    if (failed.isEmpty()) {
        echo '✓ SECURITY GATE PASSED'
        return
    }
    for (String n : failed) { enforcePolicy(n, policyFor(n), RESULTS[n].detail) }
}

// =============================================================================
//  Rollback + cleanup
// =============================================================================
def dockerRollbackIfNeeded() {
    if (env.DOCKER_DEPLOY_TOUCHED != 'true') { echo 'The deployment had not started - nothing to roll back.'; return }
    if (!flag(EFF.ROLLBACK_ENABLED, true)) { echo 'ERROR: Docker deployment failed. ROLLBACK_ENABLED=false, so the previous version is NOT restored automatically.'; return }
    echo 'ERROR: Docker deployment failed (container start or health check). Attempting rollback...'
    try {
        withRegistry { sh "bash ${env.SCRIPTS_DIR}/docker-rollback.sh auto" }
        withHealthCreds { sh "bash ${env.SCRIPTS_DIR}/health-check.sh" }
        echo 'ROLLBACK SUCCESSFUL: the previous version is running and healthy. This build stays FAILED.'
    } catch (err) {
        echo "ROLLBACK FAILED: ${err.message}. MANUAL INTERVENTION REQUIRED on ${env.NODE_NAME}."
    }
}

def dockerCleanup() {
    if (flag(EFF.DOCKER_PRUNE, true)) {
        sh 'docker image prune -f || echo "WARN: docker image prune failed (non-fatal cleanup)"'
    }
    if (flag(EFF.CLEAN_WORKSPACE, true)) { deleteDir() }
}

def iisRollbackIfNeeded() {
    if (env.IIS_DEPLOY_TOUCHED != 'true') { echo 'The deployment had not started - nothing to roll back.'; return }
    if (!flag(EFF.ROLLBACK_ENABLED, true)) { echo 'ERROR: IIS deployment failed. ROLLBACK_ENABLED=false, so the previous version is NOT restored automatically.'; return }
    echo 'ERROR: IIS application deployment failed. Restoring previous deployment...'
    try {
        psFile('iis-rollback.ps1')
        withHealthCreds { psFile('health-check.ps1') }
        echo 'ROLLBACK SUCCESSFUL: the previous version is running and healthy. This build stays FAILED.'
    } catch (err) {
        echo "ROLLBACK FAILED: ${err.message}. MANUAL INTERVENTION REQUIRED on ${env.NODE_NAME} (backups: ${EFF.IIS_BACKUP_ROOT})."
    }
}

// =============================================================================
//  Notifications and final banner
// =============================================================================
def finalBanner() {
    String result = currentBuild.currentResult
    String icon = (result == 'SUCCESS') ? '✓' : ((result == 'UNSTABLE') ? '⚠' : '✗')
    return "\n${icon} ${result}  -  ${(EFF ?: CFG).APP_NAME} | ${params.ACTION} | ${params.DEPLOY_TYPE} | ${params.ENVIRONMENT} | build #${env.BUILD_NUMBER}\n"
}

def esc(Object v) {
    return (v == null ? '' : v.toString()).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
}

def emailHtml(Map c, String status) {
    String color = [SUCCESS: '#2e7d32', UNSTABLE: '#ef6c00', FAILURE: '#c62828', ABORTED: '#616161'][status] ?: '#616161'
    String health = (c.HEALTH_CHECK_URL ?: '').toString().tokenize('?')[0] ?: '-'      // never show a query string
    String target = 'none (CI and security checks only)'
    if (params.DEPLOY_TYPE == 'docker') {
        target = "container ${c.DOCKER_CONTAINER ?: c.APP_NAME}, image ${env.IMAGE_REF ?: 'n/a'}"
    } else if (params.DEPLOY_TYPE == 'iis') {
        target = "IIS site ${c.IIS_SITE_NAME ?: 'from path'}, path ${c.IIS_SITE_PATH ?: 'read from IIS'}, pool ${c.IIS_APP_POOL ?: 'read from IIS'}"
    }
    String sec = ''
    for (String n : ['sonarqube', 'owasp', 'trivy']) {
        Map r = RESULTS[n] ?: [status: 'SKIPPED', detail: '']
        sec += "<tr><td>${n}</td><td>${esc(r.status)}</td><td>${esc(r.detail)}</td></tr>"
    }
    return """<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222">
<h2 style="margin:0;padding:10px 14px;color:#fff;background:${color}">${status}: ${esc(c.APP_NAME)} &rarr; ${esc(params.ENVIRONMENT)}</h2>
<table cellpadding="6" style="border-collapse:collapse;margin-top:10px">
<tr><td><b>Action / type</b></td><td>${esc(params.ACTION)} / ${esc(params.DEPLOY_TYPE)}</td></tr>
<tr><td><b>Branch / commit</b></td><td>${esc(c.BRANCH)} @ ${esc(env.GIT_COMMIT_SHORT ?: 'n/a')}</td></tr>
<tr><td><b>Build</b></td><td>#${env.BUILD_NUMBER} (${esc(currentBuild.durationString)})</td></tr>
<tr><td><b>Deployed to</b></td><td>${esc(target)}</td></tr>
<tr><td><b>Health check</b></td><td>${esc(health)}</td></tr>
</table>
<h3>Security checks</h3>
<table border="1" cellpadding="5" style="border-collapse:collapse"><tr><th>Check</th><th>Result</th><th>Details</th></tr>${sec}</table>
<p><a href="${env.BUILD_URL}">Build</a> | <a href="${env.BUILD_URL}console">Console log</a> | <a href="${env.BUILD_URL}artifact/">Reports</a></p>
</body></html>"""
}

def notifyAll(String status) {
    if (params.ACTION == 'discover-iis') { return }
    Map c = EFF ? EFF : CFG
    String notifyOn = (c.NOTIFY_ON ?: 'SUCCESS,FAILURE,UNSTABLE,ABORTED').toString().toUpperCase()
    String icon = [SUCCESS: '✓', UNSTABLE: '⚠', FAILURE: '✗', ABORTED: '■'][status] ?: '?'
    String msg = "${icon} ${status}: ${c.APP_NAME} | ${params.ACTION} ${params.DEPLOY_TYPE} -> ${params.ENVIRONMENT} | build #${env.BUILD_NUMBER} | commit ${env.GIT_COMMIT_SHORT ?: 'n/a'} | ${env.BUILD_URL}"
    echo msg
    if (!notifyOn.contains(status)) {
        echo "Notifications are not enabled for ${status} (NOTIFY_ON=${notifyOn})."
        return
    }

    if (c.NOTIFY_EMAIL?.toString()?.trim()) {
        try {
            Map m = [to: c.NOTIFY_EMAIL.toString(),
                     subject: "[${status}] ${c.APP_NAME} -> ${params.ENVIRONMENT} (${params.DEPLOY_TYPE}) #${env.BUILD_NUMBER}".toString(),
                     body: emailHtml(c, status), mimeType: 'text/html', charset: 'UTF-8']
            if (c.NOTIFY_EMAIL_CC?.toString()?.trim())   { m.cc = c.NOTIFY_EMAIL_CC.toString() }
            if (c.NOTIFY_EMAIL_FROM?.toString()?.trim()) { m.from = c.NOTIFY_EMAIL_FROM.toString() }
            mail(m)
            echo "E-mail notification sent to ${c.NOTIFY_EMAIL}"
        } catch (err) {
            echo "WARN: e-mail notification failed (non-fatal): ${err.message}. Check Manage Jenkins > System > E-mail Notification (SMTP)."
        }
    }
    for (String credKey : ['NOTIFY_SLACK_CRED_ID', 'NOTIFY_TEAMS_CRED_ID']) {
        String credId = (c[credKey] ?: '').toString().trim()
        if (!credId) { continue }
        try {
            String safe = msg.replace('"', '').replace('\\', '')
            node(c.AGENT_BUILD) {
                withCredentials([string(credentialsId: credId, variable: 'NOTIFY_URL')]) {
                    withEnv(['NOTIFY_PAYLOAD={"text":"' + safe + '"}']) {
                        sh '''
                            printf 'url = "%s"\\n' "$NOTIFY_URL" | curl -sS --fail -X POST -H 'Content-Type: application/json' --data-binary "$NOTIFY_PAYLOAD" -K - > /dev/null
                        '''
                    }
                }
            }
        } catch (err) {
            echo "WARN: ${credKey} notification failed (non-fatal): ${err.message}"
        }
    }
}
