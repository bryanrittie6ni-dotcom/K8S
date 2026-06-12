FROM nginx:alpine

# 自定义 nginx 配置（监听 3000 端口，SPA 回退）
COPY nginx.conf /etc/nginx/nginx.conf

# 前端静态资源
COPY dist/ /usr/share/nginx/html/

EXPOSE 3000

CMD ["nginx", "-g", "daemon off;"]
