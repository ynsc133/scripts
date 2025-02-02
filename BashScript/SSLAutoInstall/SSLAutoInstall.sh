#!/bin/bash

#Some constans here

CERT_DOMAIN=''
CERT_DEFAULT_INSTALL_PATH='/root/hysteria/cert/'
#包管理工具
PACKAGE_MANAGER=''

# 检测系统发行版
if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ $ID == "ubuntu" || $ID == "debian" ]]; then
        PACKAGE_MANAGER="apt"
    elif [[ $ID == "rhel" || $ID == "centos" || $ID == "oracle" || $ID == "rocky" || $ID == "almalinux" ]]; then
        PACKAGE_MANAGER="yum"
    else
        echo "Unsupported Linux distribution."
        exit 1
    fi
elif [ -f /etc/redhat-release ]; then
    PACKAGE_MANAGER="yum"
else
    echo "Unsupported Linux distribution."
    exit 1
fi


#function for user choice
confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

#function for user choice
install_acme() {
    cd ~
    echo "开始安装acme脚本..."
    curl https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        echo "acme安装失败"
        return 1
    else
        echo "acme安装成功"
    fi
    return 0
}

#function for domain check
domain_valid_check() {
    local domain=""
    read -p "请输入你的域名:" domain
    echo "你输入的域名为:${domain},正在进行域名合法性校验..."
    #here we need to judge whether there exists cert already
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ ${currentCert} == ${domain} ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        echo "域名合法性校验失败,当前环境已有对应域名证书,不可重复申请,当前证书详情:"
        echo "如果需要删除域名信息，请执行下方命令"
        echo "~/.acme.sh/acme.sh --remove -d ${domain}"
        echo "rm ~/.acme.sh/${domain}_ecc"
        echo "$certInfo"
        exit 1
    else
        echo "证书有效性校验通过..."
        CERT_DOMAIN=${domain}
    fi
}
#function for domain check
install_path_set() {
    cd ~
    local InstallPath=''
    read -p "请输入证书安装路径(回车默认为/root/hysteria/cert/):" InstallPath
    if [[ -n ${InstallPath} ]]; then
        echo "你输入的路径为:${InstallPath}"
    else
        InstallPath=${CERT_DEFAULT_INSTALL_PATH}
        echo "输入路径为空,将采用默认路径:${CERT_DEFAULT_INSTALL_PATH}"
    fi

    if [ ! -d "${InstallPath}" ]; then
        mkdir -p "${InstallPath}"
    else
        rm -rf "${InstallPath}"
        mkdir -p "${InstallPath}"
    fi

    if [ $? -ne 0 ]; then
        echo "设置安装路径失败,请确认"
        exit 1
    fi
    CERT_DEFAULT_INSTALL_PATH=${InstallPath}
}

#fucntion for port check
port_check() {
    if [ $# -ne 1 ]; then
        echo "参数错误,脚本退出..."
        exit 1
    fi
    port_progress=$(lsof -i:$1 | wc -l)
    if [[ ${port_progress} -ne 0 ]]; then
        echo "检测到当前端口存在占用,请更换端口或者停止该进程"
        return 1
    fi
    return 0
}

#function for cert issue entry
ssl_cert_issue() {
    local method=""
    echo -E ""
    echo "该脚本目前提供两种方式实现证书签发"
    echo "方式1:acme standalone mode,需要保持端口开放(例:site.example.com)"
    echo "方式2:acme DNS API mode,需要提供Cloudflare Global API Key(泛域名例:example.com)"
    echo "如域名属于免费域名,则推荐使用方式1进行申请"
    echo "如域名非免费域名且使用Cloudflare进行解析使用方式2进行申请"
    read -p "请选择你想使用的方式,请输入数字1或者2后回车": method
    echo "你所使用的方式为${method}"

    if [ "${method}" == "1" ]; then
        ssl_cert_issue_standalone
    elif [ "${method}" == "2" ]; then
        ssl_cert_issue_by_cloudflare
    else
        echo "输入无效,请检查你的输入,脚本将退出..."
        exit 1
    fi
}

#method for standalone mode
ssl_cert_issue_standalone() {
    #install acme first
    install_acme
    if [ $? -ne 0 ]; then
        echo "无法安装acme,请检查错误日志"
        exit 1
    fi
    #install socat second

    ${PACKAGE_MANAGER} install socat -y

    if [ $? -ne 0 ]; then
        echo "无法安装socat,请检查错误日志"
        exit 1
    else
        echo "socat安装成功..."
    fi
    #creat a directory for install cert
    install_path_set
    #domain valid check
    domain_valid_check
    #get needed port here
    local WebPort=80
    read -p "请输入你所希望使用的端口（如果使用非80端口，则此端口需要满足反代至80端口）,如回车将使用默认80端口:" WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        echo "你所选择的端口${WebPort}为无效值,将使用默认80端口进行申请"
        WebPort=80
    fi
    echo "将会使用${WebPort}端口进行证书申请,现进行端口检测,请确保端口处于开放状态..."
    #open the port and kill the occupied progress
    port_check ${WebPort}
    if [ $? -ne 0 ]; then
        echo "端口检测失败,请确保不被其他程序占用,脚本退出..."
        echo "例子-关闭nginx：systemctl stop nginx"
        exit 1
    else
        echo "端口检测成功..."
    fi

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d ${CERT_DOMAIN} --standalone --httpport ${WebPort}
    if [ $? -ne 0 ]; then
        echo "证书申请失败,原因请参见报错信息"
        exit 1
    else
        echo "证书申请成功,开始安装证书..."
    fi
    #install cert
    ~/.acme.sh/acme.sh --installcert -d ${CERT_DOMAIN} --ca-file /root/hysteria/cert/ca.cer \
    --cert-file /root/hysteria/cert/${CERT_DOMAIN}.cer --key-file /root/hysteria/cert/${CERT_DOMAIN}.key \
    --fullchain-file /root/hysteria/cert/fullchain.cer

    if [ $? -ne 0 ]; then
        echo "证书安装失败,脚本退出"
        exit 1
    else
        echo "证书安装成功,开启自动更新..."
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo "自动更新设置失败,脚本退出"
        chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
        exit 1
    else
        echo "证书已安装且已开启自动更新,具体信息如下"
        ls -lah ${CERT_DEFAULT_INSTALL_PATH}
        chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
    fi

}

#method for DNS API mode
ssl_cert_issue_by_cloudflare() {
    echo -E ""
    echo "该脚本将使用Acme脚本申请证书,使用时需保证:"
    echo "1.知晓Cloudflare 注册邮箱"
    echo "2.知晓Cloudflare Global API Key"
    echo "3.域名已通过Cloudflare进行解析到当前服务器"
    confirm "我已确认以上内容[y/n]" "y"
    if [ $? -eq 0 ]; then
        install_acme
        if [ $? -ne 0 ]; then
            echo "无法安装acme,请检查错误日志"
            exit 1
        fi
        #creat a directory for install cert
        install_path_set
        #Set DNS API
        CF_GlobalKey=""
        CF_AccountEmail=""

        #domain valid check
        domain_valid_check
        echo "请设置API密钥:"
        read -p "Input your key here:" CF_GlobalKey
        echo "你的API密钥为:${CF_GlobalKey}"
        echo "请设置注册邮箱:"
        read -p "Input your email here:" CF_AccountEmail
        echo "你的注册邮箱为:${CF_AccountEmail}"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if [ $? -ne 0 ]; then
            echo "修改默认CA为Lets'Encrypt失败,脚本退出"
            exit 1
        fi
        export CF_Key="${CF_GlobalKey}"
        export CF_Email=${CF_AccountEmail}
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CERT_DOMAIN} -d *.${CERT_DOMAIN} --log
        if [ $? -ne 0 ]; then
            echo "证书签发失败,脚本退出"
            exit 1
        else
            echo "证书签发成功,安装中..."
        fi
        ~/.acme.sh/acme.sh --installcert -d ${CERT_DOMAIN} -d *.${CERT_DOMAIN} --ca-file /root/hysteria/cert/ca.cer \
        --cert-file /root/hysteria/cert/${CERT_DOMAIN}.cer --key-file /root/hysteria/cert/${CERT_DOMAIN}.key \
        --fullchain-file /root/hysteria/cert/fullchain.cer
        if [ $? -ne 0 ]; then
            echo "证书安装失败,脚本退出"
            exit 1
        else
            echo "证书安装成功,开启自动更新..."
        fi
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            echo "自动更新设置失败,脚本退出"
            ls -lah cert
            chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
            exit 1
        else
            echo "证书已安装且已开启自动更新,具体信息如下"
            ls -lah ${CERT_DEFAULT_INSTALL_PATH}
            chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
        fi
    else
        echo "脚本退出..."
        exit 1
    fi
}

ssl_cert_issue
