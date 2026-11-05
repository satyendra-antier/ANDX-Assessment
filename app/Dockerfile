FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY tsconfig.json ./
COPY src ./src
COPY migrations ./migrations
RUN npm install tsx typescript --no-save
CMD ["npx", "tsx", "src/main.ts"]
