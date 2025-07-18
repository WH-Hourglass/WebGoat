pipeline {
    agent { label 'master' }

    environment {
        JAVA_HOME   = "/usr/lib/jvm/java-17-amazon-corretto.x86_64"
        PATH        = "${env.JAVA_HOME}/bin:${env.PATH}"
        SSH_CRED_ID = "WH1_key"
        DYNAMIC_IMAGE_TAG = "dev-${env.BUILD_NUMBER}-${sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()}"
        REPO_URL = 'https://github.com/WH-Hourglass/WebGoat.git'
        BRANCH = 'develop'
    }
    // 테스트용 주석
    // 테스트용 주석2
    // 테스트용 주석3
    // 테스트용 주석4
    // 테스트용 주석5
    // 테스트용 주석6

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

        
        stage('🚀 Generate SBOM for each commit') {
            steps {
                script {
                    load 'components/scripts/generate_sbom_1.groovy'
                    //원래는 components/scripts/generate_sbom.groovy
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

        //stage('🔍 ZAP 스캔 및 SecurityHub 전송') {
          //  agent { label 'DAST' }
            //steps {
                // sh 'DYNAMIC_IMAGE_TAG=${DYNAMIC_IMAGE_TAG} components/scripts/DAST_Zap_Scan.sh'
                //sh nohup bash -c "DYNAMIC_IMAGE_TAG=${DYNAMIC_IMAGE_TAG} components/scripts/DAST_Zap_Scan.sh" > zap_bg.log 2>&1 &

           // }
       // }

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
