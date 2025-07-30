pipeline {
    agent { label 'master' }

    environment {
        JAVA_HOME   = "/usr/lib/jvm/java-17-amazon-corretto.x86_64"
        PATH        = "${env.JAVA_HOME}/bin:${env.PATH}"
        SSH_CRED_ID = "WH1_key"
        DYNAMIC_IMAGE_TAG = "dev-${env.BUILD_NUMBER}-${sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()}"
        ECR_REPO = "535052053335.dkr.ecr.ap-northeast-2.amazonaws.com/wh_1/devpos"
        S3_BUCKET = "webgoat-codedeploy-bucket-soobin"
        DEPLOY_APP = "webgoat-cd-app"
        DEPLOY_GROUP = "webgoat-deploy-group"
        REGION = "ap-northeast-2"
        BUNDLE = "deploy2.zip"
        SONARQUBE_ENV = "WH_sonarqube"
        S3_BUCKET_DAST = "testdast"
    }

    // 업데이트1
   
    stages {
        stage('📦 Checkout') {
            steps {
                checkout scm
            }
        }
        
       stage('🧪 SonarQube Background') {
    agent { label 'SAST' }
    steps {
        withSonarQubeEnv(env.SONARQUBE_ENV) {
            sh '''
                chmod +x components/scripts/run_sonar_pipeline.sh
                export SONAR_AUTH_TOKEN=$SONAR_AUTH_TOKEN;
                export SONAR_HOST_URL=$SONAR_HOST_URL;
                nohup bash components/scripts/run_sonar_pipeline.sh > sonar_pipeline.log 2>error.log &
            '''
        }
    }
}
        
        stage('🔨 Build JAR') {
            steps {
                sh 'components/scripts/Build_JAR.sh'
            }
        }
        

        stage('🚀 Generate SBOM via CDXGEN Docker') {
            agent { label 'SCA' }
            steps {
                script {
                    def repoUrl = scm.userRemoteConfigs[0].url
                    def repoName = repoUrl.tokenize('/').last().replace('.git', '')
        
                    // 백그라운드로 실행 (nohup)
                    sh """
                        chmod +x components/scripts/run_sbom.sh
                        nohup bash components/scripts/run_sbom.sh '${repoUrl}' '${repoName}' '${env.BUILD_NUMBER}' > /tmp/sbom.log 2>&1 &
                    """
                }
            }
        }




        stage('🐳 Docker Build') {
            steps {
                sh 'DYNAMIC_IMAGE_TAG=${DYNAMIC_IMAGE_TAG} components/scripts/Docker_Build.sh'
            }
        }

        stage('🔐 ECR Login') {
            steps {
                sh 'components/scripts/ECR_Login.sh'
            }
        }

        stage('🚀 Push to ECR') {
            steps {
                sh 'DYNAMIC_IMAGE_TAG=${DYNAMIC_IMAGE_TAG} components/scripts/Push_to_ECR.sh'
            }
        }

        stage('🔍 ZAP 스캔 및 SecurityHub 전송') {
            agent { label 'DAST' }
             steps {
            sh'''
                      aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_REPO"
                    '''

                sh'nohup env DYNAMIC_IMAGE_TAG=${DYNAMIC_IMAGE_TAG} components/scripts/DAST_Zap_Scan.sh /WebGoat > zap_bg_${BUILD_NUMBER}.log 2>&1 '

            }
        }

        stage('🧩 Generate taskdef.json') {
            steps {
                script {
                    def runTaskDefGen = load 'components/functions/generateTaskDef.groovy'
                    runTaskDefGen(env)
                }
            }
        }

        stage('📄 Generate appspec.yaml') {
            steps {
                script {
                    def runAppSpecGen = load 'components/functions/generateAppspecAndWrite.groovy'
                    runAppSpecGen(env.REGION)
                }
            }
        }

        stage('📦 Bundle for CodeDeploy') {
            steps {
                sh 'components/scripts/Bundle_for_CodeDeploy.sh'
            }
        }

        stage('🚀 Deploy via CodeDeploy') {
            steps {
                sh 'components/scripts/Deploy_via_CodeDeploy.sh'
            }
        }
    }

    post {
        success {
            echo "✅ Successfully built, pushed, and deployed!"
        }
        failure {
            echo "❌ Build or deployment failed. Check logs!"
        }
    }
}
