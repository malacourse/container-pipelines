library identifier: "pipeline-library@master",
retriever: modernSCM(
  [
    $class: "GitSCMSource",
    remote: "https://github.com/redhat-cop/pipeline-library.git"
  ]
)

openshift.withCluster() {
  env.POM_FILE = env.BUILD_CONTEXT_DIR ? "${env.BUILD_CONTEXT_DIR}/pom.xml" : "pom.xml"
  env.TARGET = env.BUILD_CONTEXT_DIR ? "${env.BUILD_CONTEXT_DIR}/target" : "target"
  env.BUILD = openshift.project()
  echo "Starting Pipeline for ${APP_NAME}..."
}

pipeline {
  agent {
    label 'maven'
  }

  stages {
    stage('Git Checkout') {
      steps {
        git url: "${APPLICATION_SOURCE_REPO}", branch: "${APPLICATION_SOURCE_REF}"
      }
    }

    stage('Build') {
      steps {
        sh "mvn -B clean install -DskipTests=true -f ${POM_FILE}"
      }
    }

    stage('Unit Test') {
      steps {
        sh "mvn -B test -f ${POM_FILE}"
      }
    }

    stage('Build Container Image') {
      steps {
        sh """
          ls ${TARGET}/*
          rm -rf oc-build && mkdir -p oc-build/deployments
          for t in \$(echo "jar;war;ear" | tr ";" "\\n"); do
            cp -rfv ./${TARGET}/*.\$t oc-build/deployments/ 2> /dev/null || echo "No \$t files"
          done
        """
        binaryBuild(projectName: env.BUILD, buildConfigName: env.APP_NAME, artifactsDirectoryName: "oc-build")
      }
    }

    stage('Initialize Deployment') {
      agent { label 'ansible-slave' }
      steps {
          git url: "${APPLICATION_SOURCE_REPO}", branch: "${APPLICATION_SOURCE_REF}"
          sh '''         
            URL="${BUILD_CONTEXT_DIR}/.openshift/configmaps/configList.txt"
            echo $URL
            cat $URL
            oc version
            while IFS= read -r line; do
               echo "Text read from file: $line"
               T="$(cut -d' ' -f1 <<<"$line")"
               if [ $T = "env" ]; then
                 echo "Env Config Map"
                 NM="$(cut -d' ' -f2 <<<"$line")"
                 echo $NM
                 FP="$(cut -d' ' -f3 <<<"$line")"
                 echo $FP
                 mkdir -p "${BUILD_CONTEXT_DIR}/.openshift/files"
                 oc create cm $NM --from-file="${BUILD_CONTEXT_DIR}/$FP" --dry-run=true -o yaml > "${BUILD_CONTEXT_DIR}/.openshift/files/$NM.yml"
               fi
            done < "$URL"            
            oc apply -f "${BUILD_CONTEXT_DIR}/.openshift/files" -n "${DEV_NAMESPACE}"
            echo 'Done'
           '''
      }
    }


    stage('Promote Image from Build to Dev') {
      steps {
        tagImage(sourceImageName: env.APP_NAME, sourceImagePath: env.BUILD, toImagePath: env.DEV_NAMESPACE)
      }
    }

    stage('Deploy Templates to Dev') {
      agent { label 'ansible-slave' }
      steps {
        //git url: "${APPLICATION_SOURCE_REPO}", branch: "${APPLICATION_SOURCE_REF}"
        sh """
          ansible-galaxy install -r ./${env.ANSIBLE_CONTEXT_DIR}/requirements.yml -p .
          ansible-playbook -i ./${env.ANSIBLE_INVENTORY_DIR}/deploy ./openshift-applier/playbooks/openshift-cluster-seed.yml -e filter_tags='deploy'
        """
      }
    }

    stage('Verify Deployment to Dev') {
      steps {
        verifyDeployment(projectName: env.DEV_NAMESPACE, targetApp: env.APP_NAME)
      }
    }

  }

}

println "Application ${env.APP_NAME} is now in Production!"
