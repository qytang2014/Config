添加 nodeget 一键部署脚本
使用方法：
```
bash <(wget -qO- https://raw.githubusercontent.com/qytang2014/Config/refs/heads/master/nodeget/nodeget_deploy.sh)
```
脚本支持下面功能：
- 一键自动化安装 主控服务，自建dashboard，status show 公共前端
- 自动申请相关域名证书及 nginx 反代
- 支持一键更新所有安装的模块
- 一键卸载所有部署内容

在执行上面脚本前，如果要在 vps 上自建 dashboard并且部署 status show 公共前端的话，准备三个域名，并做好DNS解析，可以部署在同一台VPS上, 三个域名分别用于:
- 主控接口
- 自建 Dashboard 后台管理面板
- 公开探针页面，给别人看的状态页

然后根据脚本提示输入，脚本会自动配置好 nginx 反代及证书申请(脚本执行过程中会强制断开非 nginx 进程占用80 443端口的进程)

部署成功后，访问 dashboard 页面添加相应的 server 及 agent 即可完成
