#!/bin/bash
stty erase ^H



TIME() {
  [[ -z "$1" ]] && {
    echo -ne " "
  } || {
    case $1 in
    r) export Color="\e[31;1m" ;;
    g) export Color="\e[32;1m" ;;
    b) export Color="\e[34;1m" ;;
    y) export Color="\e[33;1m" ;;
    z) export Color="\e[35;1m" ;;
    l) export Color="\e[36;1m" ;;
    esac
    [[ $# -lt 2 ]] && echo -e "\e[36m\e[0m ${1}" || {
      echo -e "\e[36m\e[0m ${Color}${2}\e[0m"
    }
  }
}

CHECK_SERVER_EVN(){
  [[ ! "$USER" == "root" ]] && {
    echo
    TIME r "警告：请使用root用户操作!~~"
    echo
    exit 1
  }


  if ! command -v curl; then
    yum -y install curl
  fi

  if ! command -v curl; then
    echo
    TIME r "curl命令不可用,请手动安装curl!!!!!!~~"
    echo
    exit 1
  fi

  if ! command -v jq; then
    yum -y install jq
  fi


  if ! command -v jq; then
    echo
    TIME r "jq命令不可用,请手动安装jq!!!!!!~~"
    echo
    exit 1
  fi
}

INSTALL_DOCKER(){

  if [[ $(docker --version | grep -c "version") -ge '1' ]]; then
    echo
    TIME g "检测到docker存在，跳过安装docker!" 
  else
    TIME r "开始安装docker，过程较长，请耐心等待执行完毕。如安装失败请尝试其他方式自行安装docker。"
    curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    TIME y "设置docker镜像仓库"
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json <<-'EOF'
        {
          "registry-mirrors": [
            "https://mirror.ccs.tencentyun.com"
          ]
        }
EOF
    TIME y "重启docker"
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    TIME g "安装docker执行完成"
  fi
}

UNINSTALL_SERVER(){
  echo
  TIME r "开始卸载旧版服务端（不删除数据库）！"
  echo
  sudo docker rm -f yuanshen
  rm -rf $yuanshen_app_path
  versions="$yuanshen_manager_url/dict/versions"
  versionsStr=$(curl -X GET $versions)
  array=(`echo $versionsStr | tr ',' ' '` )
  for value in ${array[@]};
  do
    sudo docker rmi registry.cn-hangzhou.aliyuncs.com/gebilaoyu/yuanshen:$value
  done;

  echo
  TIME g "卸载完成（不删除数据库）！"
  echo
}

RESTINSTALL_DB(){
  TIME r "停止并启动数据库（不删除原有数据，如需迁移请再重启完成后将旧数据复制到目录 $yuanshen_app_data_path/yuanshen/db"
  sudo docker rm -f mongo 
  sudo docker run -dit --network server-network --name mongo -p $yuasnhen_db_port:27017 -v $yuanshen_db_path:/data/db mongo:4.2.18
  TIME g "重启数据库完成"
}

RESTINSTALL_SERVER(){
  echo
  TIME r "开始运行服务端"
  echo
  clientDataPath="/etc/gbly"
  clientJson=client.json
  if [ ! -d "$clientDataPath" ]; then
    mkdir $clientDataPath
  fi

  if [ ! -f "$clientDataPath/$clientJson" ]; then
    wget $yuanshen_manager_url/gen/client -O $clientDataPath/$clientJson
    chmod -R 777 $clientDataPath 
  fi
  clientId=$(jq .clientId $clientDataPath/$clientJson |sed 's/\"//g')
  publicKey=$(jq .publicKey $clientDataPath/$clientJson |sed 's/\"//g')
  clientExist=$(curl -X GET https://manager.easydo.plus/exist/$clientId)
  if [ "$clientExist" = "false" ]; then
    wget $yuanshen_manager_url/gen/client -O $clientDataPath/$clientJson
    chmod -R 777 $clientDataPath 
    clientId=$(jq .clientId $clientDataPath/$clientJson |sed 's/\"//g')
    publicKey=$(jq .publicKey $clientDataPath/$clientJson |sed 's/\"//g')
  fi
  sudo docker run -dit -e CLIENT_ID=$clientId -e PUBLIC_KEY=$publicKey -e PUBLIC_IP=$yuanshen_public_ip -e WEB_PORT=$yuanshen_web_port -e GAME_PORT=$yuasnhen_game_port -e MONGO_DB=mongo:27017 --network server-network -p $yuanshen_manager_port:9999 -p $yuasnhen_game_port:22102/udp -p $yuanshen_web_port:$yuanshen_web_port -v $yuanshen_cert_path:/cert -v $yuanshen_app_path:/app --name yuanshen registry.cn-hangzhou.aliyuncs.com/gebilaoyu/yuanshen:$version

}

INSTALL_PROXY(){
  TIME r "是否安装代理转发,支持安卓端连接，IOS自测!"
  echo
  while :; do
    read -p " [输入[ N/n ]回车跳过安装代理，输入[ Y/y ]回车安装代理]： " ANDK
    case $ANDK in
    [Yy])
      proxy_port=8080
      TIME y "请指定代理端口,回车默认 8080"
      read input
      if [ -z "${input}" ]; then
        input=$proxy_port
      fi
      proxy_port=$input
      TIME r "停止代理程序"
      docker rm -f yuanshen-proxy
      docker network disconnect --force bridge yuanshen-proxy
      TIME r "开始安装代理"
      sudo docker pull registry.cn-hangzhou.aliyuncs.com/gebilaoyu/proxy:latest
      sudo docker run -dit -e PROXY_PORT=$yuanshen_web_port -e PROXY_IP=yuanshen  -p $proxy_port:8080 --network server-network --name yuanshen-proxy -v $yuanshen_cert_path:/root/.mitmproxy -v $yuanshen_proxy_path:/data/log registry.cn-hangzhou.aliyuncs.com/gebilaoyu/proxy:latest
      TIME g "代理安装完成"
      break
      ;;
    [Nn])
      echo
      TIME g "跳过安装代理!"
      echo
      break
      ;;
    *)
      echo
      TIME b "提示：请输入正确的选择!"
      echo
      ;;
    esac
  done
}

AUTO_GET_CERT(){
  TIME r "在进行证书申请前请将域名解析至本服务器的外网ip地址: $yuanshen_public_ip,并确保没有nginx等其程序正在占用80端口，处理完毕后回车继续操作。"
  read input

  TIME y "开始部署证书续签服务。请等待........."

  docker rm -f acme
  docker run -dit --net=host --name=achme -v $acmeDataPath:/came.sh --name acme registry.cn-hangzhou.aliyuncs.com/gebilaoyu/acme.sh:3.0.4 daemon
  TIME g "完成证书续签服务部署。"

  acmeEmail=''
  TIME y "输入你的真实邮箱后回车,（https://zerossl.com）的邮箱账号,最好提前注册"
  read input
  if [ -z "${input}" ]; then
    input=$acmeEmail
  fi
  acmeEmail=$input
  TIME g "你输入的邮箱为: $acmeEmail"

  domain=''
  TIME y "输入你的域名后回车"
  read input
  if [ -z "${input}" ]; then
    input=$domain
  fi
  domain=$input
  TIME g "你输入的域名为: $domain"


  TIME y "开始尝试申请证书,请注意查看日志，此处脚本无法判断是否成功........."
  docker exec acme --issue -m $acmeEmail -d $domain --standalone
  TIME g "尝试申请证书执行完成，........."

  TIME r "尝试转换证书并替换至服务端........."
  docker exec acme --toPkcs  -d $domain  [--password pfx-password]
  cp -f $acmeDataPath/$domain/$acmeDataPath.p12 /$yuanshen_app_path/keystore.p12
  RESTART_SERVER
  TIME g "替换证书操作执行完成，不确定是否成功，请自行验证........."

}

CER_TO_P12(){
  yum install -y openssl

  TIME r "      将域名或ip的配套证书上传至 $yuanshen_app_data_path/yuanshen/cret 目录,回车继续操作"
  read input

  publicFile=certificate.crt
  TIME y "输入上传的公钥证书文件名 默认 $publicFile"
  read input
  if [ -z "${input}" ]; then
    input=$publicFile
  fi
  publicFile=$input

  privateFile=private.key
  TIME y "输入上传的私钥证书的文件名 默认 $privateFile"
  read input
  if [ -z "${input}" ]; then
    input=$privateFile
  fi
  privateFile=$input
  
  TIME y "回车后将开始转换证书,正常情况下会提示你输入两次密码,请随意设置一个密码。"
  read input
  openssl pkcs12 -export -in $yuanshen_cert_path/$publicFile -inkey $yuanshen_cert_path/$privateFile -out $yuanshen_cert_path/keystore.p12


  certPass=""
  TIME y "输入刚才配置的密码，程序将自动替换证书和配置文件"
  read input
  if [ -z "${certPass}" ]; then
    certPass=$privateFile
  fi
  certPass=$input
  cp -f $yuanshen_cert_path/keystore.p12 /$yuanshen_app_path/keystore.p12
  sed -i "s/123456/$certPass/g" $yuanshen_app_path/config.json
  RESTART_SERVER
  TIME g "已将证书转换为p12格式并替换至服务端,游览器打开 https://$yuanshen_public_ip:$yuanshen_web_port ,如果https为安全状态则代表成功。回车继续。"
  read input
}


INSTALL_IP_CERT(){
   TIME y "开始前请确保没有其他程序占用80端口，如有则先暂时停止,证书验证完毕后将自动释放80端口。回车继续。"
   read input
   docker rm -f yuanshen-nginx
   wget https://manager.easydo.plus/download/yuanshen-nginx.conf -O $yuanshen_app_data_path/yuanshen/nginx/yuanshen-nginx.conf
   docker run -dit --name yuanshen-nginx -p 80:8080 -v $yuanshen_app_data_path/yuanshen/nginx/yuanshen-nginx.conf:/opt/bitnami/nginx/conf/server_blocks/my_server_block.conf:ro -v $yuanshen_app_data_path/yuanshen/nginx:/html/.well-known/pki-validation/ bitnami/nginx:1.20.2
   TIME g "验证服务已就绪,现在你需要做完以下事情才能继续回车往下走：
           1.前往https://app.zerossl.com/dashboard 登录申请IP证书，选择90天有效期的免费IP证书。
           2.按照提示往下走，在验证方式处选择 HTTP File Upload
           3.点击 Download Auth File 下载验证的txt文件，将文件上至 $yuanshen_app_data_path/yuanshen/nginx 目录
           4.现在回到网页往下走点击验证。 验证通过后在页面等待证书签发。
           5.签发完毕后会给你发送邮件，此时页面的下载按钮可点击。 下载证书，类型选择默认即可，
           6.现在你可以回车继续了。"
   read input 
   docker rm -f yuanshen-nginx
   TIME r "7.下载并准备好你的证书，按照提示上传证书到指定目录，进行证书转换和替换操作"
   read input
   CER_TO_P12
}


INSTALL_CERT(){
  TIME r "是否安装域名或ip证书?"
  echo
  while :; do
    read -p " [ [ N/n ]跳过安装证书, [ 1 ]自动安装域名证书(不稳定),[ 2 ]普通证书转服务端证书, [ 3 ] 引导安装IP安全证书(白嫖很稳)]： " ANDK
    case $ANDK in
    [1])
      AUTO_GET_CERT
      break
      ;;
    [2])
      CER_TO_P12
      break
      ;;
    [3])
      INSTALL_IP_CERT
      break
      ;; 
    [Nn])
      TIME g "跳过安装证书."
      break
      ;;
    *)
      echo
      TIME b "提示：请输入正确的选择!"
      echo
      ;;
    esac
  done
}

CHECK_SERVER_START(){
  while [ 1 ]; do
    if [ -f "$yuanshen_app_path/logs/latest.log" ]; then
      sleep 1s
      echo
      TIME g "服务端启动成功."
      echo
      break
    else
      TIME y "等待启动完成......"
      sleep 1s
      fi
  done 
}

SET_DATA_PATH(){

  yuanshen_app_data_path='/data'
  

  TIME y "请指定保存数据的目录, 默认 $yuanshen_app_data_path"
  read input

  if [ -z "${input}" ]; then
    input=$yuanshen_app_data_path
  fi
  yuanshen_app_data_path=$input

  export yuanshen_app_path=$yuanshen_app_data_path/yuanshen/app
  export yuanshen_db_path=$yuanshen_app_data_path/yuanshen/db  
  export yuanshen_cert_path=$yuanshen_app_data_path/yuanshen/cert
  export yuanshen_proxy_path=$yuanshen_app_data_path/yuanshen/proxy
  export acmeDataPath=$yuanshen_app_data_path/acme

  if [ ! -d "$yuanshen_app_data_path" ]; then
    mkdir $yuanshen_app_data_path
  fi
  if [ ! -d "$yuanshen_app_data_path/yuanshen" ]; then
    mkdir $yuanshen_app_data_path/yuanshen
  fi

  if [ ! -d "$yuanshen_app_path" ]; then
    mkdir $yuanshen_app_path  
  fi

  
  if [ ! -d "$yuanshen_db_path" ]; then
    mkdir $yuanshen_db_path
  fi


  if [ ! -d "$yuanshen_cert_path" ]; then
    mkdir $yuanshen_cert_path  
  fi

  if [ ! -d "$acmeDataPath" ]; then
    mkdir $acmeDataPath
  fi

  if [ ! -d "$yuanshen_proxy_path" ]; then
    mkdir $yuanshen_proxy_path
  fi

  if [ ! -d "$yuanshen_app_data_path/yuanshen/nginx" ]; then
    mkdir $yuanshen_app_data_path/yuanshen/nginx
  fi
  
  echo
  TIME g "数据目录加载完毕！"
  echo
}



SET_APP_EVN(){
  yuanshen_public_ip='127.0.0.1'
  yuanshen_web_port=456
  yuasnhen_game_port=22102
  yuasnhen_db_port=27017
  yuanshen_manager_port=9999
  yuanshen_manager_url=www.manager.easydo.plus

  TIME y "请指定服务器外网ip地址或域名,回车默认 $yuanshen_public_ip"
  read input
  if [ -z "${input}" ]; then
    input=$yuanshen_public_ip
  fi
  yuanshen_public_ip=$input

  TIME y "请指定服务器外网端口(tcp端口) ,回车默认 $yuanshen_web_port"
  read input
  if [ -z "${input}" ]; then
    input=$yuanshen_public_ip
  fi
  yuanshen_public_ip=$input


  TIME y "请指定服务端口(upd端口) ,回车默认 $yuasnhen_game_port"
  read input
  if [ -z "${input}" ]; then
    input=$yuasnhen_game_port
  fi
  yuasnhen_game_port=$input


  TIME y "请指定数据库端口,回车默认 $yuasnhen_db_port"
  read input
  if [ -z "${input}" ]; then
    input=$yuasnhen_db_port
  fi
  yuasnhen_db_port=$input


  TIME y "请指定服务管理端口（下载代理证书等拓展功能使用）,回车默认 $yuanshen_manager_port"
  read input
  if [ -z "${input}" ]; then
    input=$yuanshen_manager_port
  fi
  yuanshen_manager_port=$input

  export yuanshen_public_ip=$yuanshen_public_ip
  export yuanshen_web_port=$yuanshen_web_port
  export yuasnhen_game_port=$yuasnhen_game_port
  export yuasnhen_db_port=$yuasnhen_db_port
  export yuanshen_manager_port=$yuanshen_manager_port
  export yuanshen_manager_url=$yuanshen_manager_url
}

ECHO_INFO(){
  echo
  TIME r "----------------------------------------请注意保存以下信息，按照提示进一步操作-----------------------------------------------------------"
  echo
  TIME y "      交流频道： https://chet.easydo.plus/channel/yuanshendocker"
  TIME y "      你的安装凭证为 $clientId" 
  TIME r "      请再服务器安全组和防火墙放行端口 $yuasnhen_game_port（udp）和 $yuanshen_web_port (tcp) $yuanshen_manager_port(tcp) , 数据库端口$yuasnhen_db_port(tcp) 出于安全考虑请不要开放数据库端口"
  TIME y "      查看启动日志：   docker logs yuanshen"
  TIME y "      查看服务端日志： tail -f $yuanshen_app_data_path/yuanshen/app/logs/latest.log"
  TIME y "      查看代理日志：   tail -f $yuanshen_proxy_path/proxy.log"
  TIME y "      更新最新版本直接运行脚本： wget https://manager.easydo.plus/download/install -O yuanshen_install.sh.x && chmod 777 yuanshen_install.sh.x && ./yuanshen_install.sh.x"
  TIME y "      服务器地址: $yuanshen_public_ip:$yuanshen_web_port"
  TIME y "      安卓直连地址： https://$yuanshen_public_ip:$yuanshen_web_port"
  TIME y "      数据库路径: $yuanshen_db_path"
  TIME y "      服务端路径: $yuanshen_app_path"

  TIME g "      移动端连接教程:

                  已经替换安全证书的用户直接下载 最新版本内置代理模块的国际服客户端.apk 选择官方服务器选项更新游戏资源。
                  更新完毕重新打开，在启动页面的弹窗中点击设置，设置服务器地址为： https://$yuanshen_public_ip:$yuanshen_web_port 
                  选择自定义服务器选项直接登录。

                  无安全证书用户,需要设置 wifi或apn 的代理地址为: $yuanshen_public_ip 端口: $proxy_port , 所有类型的代理证书存放在 $yuanshen_cert_path 目录, 
                  1.访问以下地址可直接下载服务器代理证书： http://$yuanshen_public_ip:$yuanshen_manager_port/download/azClientCert
                  2.在手机端安装代理证书
                  3.下载 最新版本内置代理模块的国际服客户端.apk 选择官方服务器更新游戏资源。 
                  4.设置WIFI的网络代理后登录游戏。
                  5.IOS客户端代理参照 1 2 步骤"
  echo
  TIME r "--------------------------------------------------------------------------------------------------------------------"
  echo
  TIME r "以上为服务端信息,请务必查看并按照提示操作,保存相关信息。按下回车将查看服务端启动日志, ctrl+c 直接退出脚本"
  read input

  tail -f $yuanshen_app_path/logs/latest.log
}




RESTART_SERVER(){
  TIME r "重启服务端........."
  rm -rf $yuanshen_app_path/logs/latest.log
  docker restart yuanshen
  CHECK_SERVER_START
}


STOP_SERVER(){
  TIME r "停止服务端........."
  docker stop yuanshen
  TIME g "停止服务端完成........."
}


RESTART_DB(){
  TIME r "重启数据库........."
  docker restart mongo
  TIME g "重启数据库完成........."
}

STOP_DB(){
  TIME r "停止数据库........."
  docker stop mongo
  TIME g "停止数据库完成........."
}

RESTART_PROXY(){
  TIME r "重启代理........."
  docker restart yuanshen-proxy
  TIME g "重启代理完成........."
}

STOP_PROXY(){
  TIME r "停止代理........."
  docker stop yuanshen-proxy
  TIME g "停止代理完成........."
}



ONE_INSTALL(){


  CHECK_SERVER_EVN

  INSTALL_DOCKER

  SET_APP_EVN

  GET_LATEST_VERSION

  TIME y "回车开始安装"
  read input

  UNINSTALL_SERVER

  TIME r "创建docker网络组erver-network"
  sudo docker network create server-network
  TIME g "创建ocker网络组完成"

  RESTINSTALL_DB

  RESTINSTALL_SERVER

  CHECK_SERVER_START

  INSTALL_PROXY

  INSTALL_CERT
  
  ECHO_INFO

}



SET_DATA_PATH

TIME g "      原神docker一键端安装脚本 by 隔壁老于,当前脚本版本为：20220515"

TIME r "      "
TIME r "
              1.一键安装(安装最新版本,不删除数据)    
              2.重启服务端
              3.停止服务端
              4.重启数据库
              5.停止数据库
              6.重启代理  
              7.停止代理
              8.查看最新版本(不安装)
              9.查看启动日志
              10.查看服务端日志
              11.查看代理日志
              12.安装证书
              "

TIME r "      "
TIME r "      "
TIME r "      "
TIME r "      " 



while :; do
  read -p " [输入数字]： " ANDK
  case $ANDK in
  [1])
    ONE_INSTALL
    break
    ;;
  [2])
    RESTART_SERVER
    break
    ;;
  [3])
    STOP_SERVER
    break
    ;;
  [4])
    RESTART_DB
    break
    ;;
  [5])
    STOP_DB
    break
    ;;
  [6])
    RESTART_PROXY
    break
    ;;
  [7])
    STOP_PROXY
    break
    ;;
  [8])
    GET_LATEST_VERSION
    break
    ;;
  [9])
    sudo docker logs yuanshen
    break
    ;;
  10)
    tail -f $yuanshen_app_path/logs/latest.log
    break
    ;;
  11)
    tail -f $yuanshen_proxy_path/proxy.log
    break
    ;;
  12)
    INSTALL_CERT
    break
    ;;
  *)
    break
    ;;
  esac
done
