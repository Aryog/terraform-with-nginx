#!/bin/bash

# Fail on any error
set -e

# Create Hadoop user
sudo useradd -m -s /bin/bash hadoop
sudo usermod -aG sudo hadoop

# Update and install dependencies
sudo apt-get update
sudo apt-get install -y openjdk-8-jdk wget nano net-tools

# Set Java and Hadoop versions
# Use readlink to correctly set JAVA_HOME
# Detect JAVA_HOME more robustly
if [ -z "$JAVA_HOME" ]; then
    # Try multiple methods to find Java home
    JAVA_PATH=$(which java)
    if [ -n "$JAVA_PATH" ]; then
        JAVA_HOME=$(readlink -f "$JAVA_PATH" | sed "s:bin/java::")
    else
        # Fallback to common OpenJDK locations
        JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
    fi
fi

# Verify Java Home exists
if [ ! -d "$JAVA_HOME" ]; then
    echo "Error: JAVA_HOME directory not found at $JAVA_HOME"
    exit 1
fi

HADOOP_VERSION="3.4.0"
HADOOP_HOME="/opt/hadoop"

# Verify Java installation
echo "JAVA_HOME is set to: $JAVA_HOME"
java -version

# Download and extract Hadoop
wget https://downloads.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz
sudo tar -xzvf hadoop-${HADOOP_VERSION}.tar.gz -C /opt/
sudo mv /opt/hadoop-${HADOOP_VERSION} ${HADOOP_HOME}

sudo tee -a $HADOOP_HOME/etc/hadoop/hadoop-env.sh << EOF

# Explicitly set JAVA_HOME
export JAVA_HOME=${JAVA_HOME}
export HADOOP_OPTS="-Djava.library.path=$HADOOP_HOME/lib/native"
EOF

# Set environment variables
sudo tee /etc/profile.d/hadoop.sh << EOF
export JAVA_HOME=${JAVA_HOME}
export HADOOP_HOME=${HADOOP_HOME}
export PATH=\$PATH:\$JAVA_HOME/bin:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export HDFS_NAMENODE_USER=hadoop
export HDFS_DATANODE_USER=hadoop
export HDFS_SECONDARYNAMENODE_USER=hadoop
EOF

sudo -u hadoop tee -a ~hadoop/.bashrc << EOF
export JAVA_HOME=${JAVA_HOME}
export HADOOP_HOME=${HADOOP_HOME}
export HADOOP_INSTALL=$HADOOP_HOME
export HADOOP_MAPRED_HOME=$HADOOP_HOME
export HADOOP_COMMON_HOME=$HADOOP_HOME
export HADOOP_HDFS_HOME=$HADOOP_HOME
export YARN_HOME=$HADOOP_HOME
export HADOOP_COMMON_LIB_NATIVE_DIR=$HADOOP_HOME/lib/native
export PATH=$PATH:$JAVA_HOME/bin:$HADOOP_HOME/sbin:$HADOOP_HOME/bin
export HADOOP_OPTS="-Djava.library.path=$HADOOP_HOME/lib/native"
EOF

# Source the environment
source /etc/profile.d/hadoop.sh
sudo -u hadoop bash -c "source ~hadoop/.bashrc"
sudo -u hadoop bash -c "source $HADOOP_HOME/etc/hadoop/hadoop-env.sh"

# Create Hadoop directories
sudo mkdir -p /data/hadoop/hdfs/namenode
sudo mkdir -p /data/hadoop/hdfs/datanode
sudo chown -R hadoop:hadoop /data/hadoop
sudo chown -R hadoop:hadoop ${HADOOP_HOME}

# Configure core-site.xml
sudo -u hadoop tee ${HADOOP_HOME}/etc/hadoop/core-site.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://localhost:9000</value>
    </property>
</configuration>
EOF

# Configure hdfs-site.xml
sudo -u hadoop tee ${HADOOP_HOME}/etc/hadoop/hdfs-site.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
    <property>
        <name>dfs.namenode.name.dir</name>
        <value>/data/hadoop/hdfs/namenode</value>
    </property>
    <property>
        <name>dfs.datanode.data.dir</name>
        <value>/data/hadoop/hdfs/datanode</value>
    </property>
</configuration>
EOF

# Configure yarn-site.xml
sudo -u hadoop tee ${HADOOP_HOME}/etc/hadoop/yarn-site.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
</configuration>
EOF

# Configure mapred-site.xml
sudo -u hadoop tee ${HADOOP_HOME}/etc/hadoop/mapred-site.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>mapreduce.framework.name</name>
        <value>yarn</value>
    </property>
</configuration>
EOF

# SSH key setup for hadoop user
sudo -u hadoop mkdir -p ~hadoop/.ssh
sudo -u hadoop ssh-keygen -t rsa -P '' -f ~hadoop/.ssh/id_rsa
sudo -u hadoop tee ~hadoop/.ssh/authorized_keys << EOF
$(sudo -u hadoop cat ~hadoop/.ssh/id_rsa.pub)
EOF

# Correct permissions using root
sudo chmod 700 ~hadoop/.ssh
sudo chmod 600 ~hadoop/.ssh/authorized_keys
sudo chown -R hadoop:hadoop ~hadoop/.ssh

# Install and configure Nginx as a reverse proxy
sudo apt-get install -y nginx

# Create Nginx configuration for Hadoop web interfaces
sudo tee /etc/nginx/sites-available/hadoop-proxy << EOF
server {
    listen 80;
    server_name _; # Listen on all available interfaces

    # HDFS NameNode WebUI
    location /namenode/ {
        proxy_pass http://localhost:9870/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # YARN ResourceManager WebUI
    location /resourcemanager/ {
        proxy_pass http://localhost:8088/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # MapReduce JobHistory Server
    location /jobhistory/ {
        proxy_pass http://localhost:19888/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# Enable Nginx configuration
sudo ln -s /etc/nginx/sites-available/hadoop-proxy /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

# Format HDFS (only on first setup)
sudo -u hadoop ${HADOOP_HOME}/bin/hdfs namenode -format -force

# Start Hadoop services
# Add full paths to Hadoop start scripts
sudo -u hadoop ${HADOOP_HOME}/sbin/start-dfs.sh
sudo -u hadoop ${HADOOP_HOME}/sbin/start-yarn.sh
sudo -u hadoop ${HADOOP_HOME}/sbin/mr-jobhistory-daemon.sh start historyserver

# Clean up downloaded tarball
rm hadoop-${HADOOP_VERSION}.tar.gz

echo "Hadoop installation complete!"
