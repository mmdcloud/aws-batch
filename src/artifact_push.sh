
#!/bin/bash
mkdir final-code
cp -r ../code/* final-code/
cd final-code
docker buildx build --tag $1 --file ./Dockerfile .
docker tag $1:latest $2-docker.pkg.dev/$3/$1/$1:latest
docker push $2-docker.pkg.dev/$3/$1/$1:latest