FROM debian:trixie
# Env vars
ENV APPIMAGE_EXTRACT_AND_RUN=1
ENV BUILT_IN_DOCKER=1

# Install and prep
RUN apt-get update \ 
&& DEBIAN_FRONTEND=noninteractive \
apt-get install -yqq --no-install-recommends \
  file build-essential sudo curl p7zip-full wget \
  libfuse-dev icoutils imagemagick nodejs npm dpkg-dev \
&& apt-get clean \
&& rm -rf /var/lib/apt/lists/* \
&& useradd -m -s /bin/bash builder \
&& echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
&& chmod 0440 /etc/sudoers

# Add the build scripts
ADD ./build.sh /home/builder/build.sh
ADD ./scripts /home/builder/scripts
RUN chown -R builder: /home/builder
WORKDIR /home/builder
USER builder

# NVM installation
# Use bash for the shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Create a script file sourced by both interactive and non-interactive bash shells
ENV BASH_ENV=/home/builder/.bash_env
RUN touch "${BASH_ENV}"
RUN echo '. "${BASH_ENV}"' >> ~/.bashrc
# Download and install nvm
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | PROFILE="${BASH_ENV}" bash
RUN echo node > .nvmrc
RUN nvm install lts/jod

# Final entrypoint to let the other flags work by overriding CMD
CMD [ "--build", "appimage", "--clean", "yes" ]
ENTRYPOINT [ "/home/builder/build.sh" ]
