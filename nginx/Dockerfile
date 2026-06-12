FROM nginx:alpine

# 复制主配置和代理通用配置
COPY nginx.conf /etc/nginx/nginx.conf
COPY proxy.conf /etc/nginx/proxy.conf

# 复制站点配置（conf.d）
COPY conf.d/ /etc/nginx/conf.d/

# SSL 证书不打包进镜像，通过 K8S Secret volume 挂载到 /etc/ssl/
# 运行时需确保 /etc/ssl 目录存在
RUN mkdir -p /etc/ssl

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
