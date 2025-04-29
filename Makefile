.PHONY: build
build:
	@echo "Building the project..."
	cd aidan-blog && yarn build --out-dir ../docs
