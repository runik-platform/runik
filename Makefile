# ============================================================================
# Runik Test Makefile
# ============================================================================
#
# Phase 1: Render Tests
#   Validate that `helm template` executes without errors.
#
# Phase 2: Snapshot Tests
#   Render helm templates and compare against saved snapshots.
#   Any difference = FAIL with colored diff output.
#
# Syntax:
#   make render glyph <name> [file]   Render glyph example(s) via kaster
#   make render summon [file]          Render summon example(s)
#   make render book <name>            Render librarian book
#   make snapshot glyph <name> [file]  Save snapshot(s) for a glyph
#   make snapshot summon [file]         Save snapshot(s) for summon
#   make snapshot book <name>           Save snapshot for a book
#   make snapshot all                   Save all snapshots
#   make test glyph <name> [file]      Test snapshot(s) for a glyph
#   make test summon [file]             Test snapshot(s) for summon
#   make test book <name>               Test snapshot for a book
#   make test all                       Test all golden snapshots
#   make list glyphs                   List available glyphs
#   make list examples <name>          List examples for a glyph/summon
#   make list books                    List available books
# ============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
KASTER_DIR     := charts/kaster
GLYPHS_DIR     := charts/glyphs
SUMMON_DIR     := charts/summon
MICROSPELL_DIR := charts/trinkets/microspell
TAROT_DIR      := charts/trinkets/tarot
LIBRARIAN_DIR  := librarian
COVENANT_DIR   := covenant
BOOKRACK_DIR   := bookrack
SNAPSHOTS_DIR  := tests/snapshots
KNOWN_EMPTY_FIXTURES := tests/known-empty-fixtures.txt
LIBRARIAN_BOOKS_FILE := tests/librarian-books.txt
COVENANT_APPLICATION_BOOKS_FILE := tests/covenant-application-books.txt
COVENANT_IAM_BOOKS_FILE := tests/covenant-iam-books.txt

TEST_RELEASE   ?= test
TEST_NAMESPACE ?= glyphs-release
HELM_TEST      := helm template $(TEST_RELEASE) --namespace $(TEST_NAMESPACE)

# ---------------------------------------------------------------------------
# Dynamic lists
# ---------------------------------------------------------------------------
GLYPHS := $(sort $(notdir $(patsubst %/examples/,%,$(wildcard $(GLYPHS_DIR)/*/examples/))))
BOOKS  := $(shell grep -Ev '^[[:space:]]*(\#|$$)' $(LIBRARIAN_BOOKS_FILE) | sort -u)
COVENANT_APPLICATION_BOOKS := $(shell grep -Ev '^[[:space:]]*(\#|$$)' $(COVENANT_APPLICATION_BOOKS_FILE) | sort -u)
COVENANT_IAM_BOOKS := $(shell grep -Ev '^[[:space:]]*(\#|$$)' $(COVENANT_IAM_BOOKS_FILE) | sort -u)

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
GREEN  := $(shell tput setaf 2 2>/dev/null || true)
RED    := $(shell tput setaf 1 2>/dev/null || true)
YELLOW := $(shell tput setaf 3 2>/dev/null || true)
CYAN   := $(shell tput setaf 6 2>/dev/null || true)
BOLD   := $(shell tput bold 2>/dev/null || true)
RESET  := $(shell tput sgr0 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Argument extraction
# ---------------------------------------------------------------------------
ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
$(eval $(ARGS):;@:)

RESOURCE := $(word 1,$(ARGS))
NAME     := $(word 2,$(ARGS))
FILE     := $(word 3,$(ARGS))

# ============================================================================
# Public targets
# ============================================================================

.PHONY: help render test snapshot list verify smoke ci
.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@echo "$(BOLD)Runik Test Makefile$(RESET)"
	@echo ""
	@echo "$(CYAN)Render:$(RESET)"
	@echo "  make render glyph <name> [file]   Render glyph example(s) via kaster"
	@echo "  make render summon [file]          Render summon example(s)"
	@echo "  make render book <name>            Render librarian book"
	@echo "  make render covenant               Render the complete Covenant fixture"
	@echo ""
	@echo "$(CYAN)Snapshot:$(RESET)"
	@echo "  make snapshot glyph <name> [file]  Save snapshot(s) for a glyph"
	@echo "  make snapshot summon [file]         Save snapshot(s) for summon"
	@echo "  make snapshot book <name>           Save snapshot for a book"
	@echo "  make snapshot all                   Save all snapshots"
	@echo ""
	@echo "$(CYAN)Test:$(RESET)"
	@echo "  make test glyph <name> [file]      Test snapshot(s) for a glyph"
	@echo "  make test summon [file]             Test snapshot(s) for summon"
	@echo "  make test book <name>               Test snapshot for a book"
	@echo "  make test integration               Test Librarian-to-trinket composition"
	@echo "  make test covenant                  Test the single Covenant instance"
	@echo "  make test all                       Test all golden snapshots"
	@echo "  make smoke                          Render kaster and trinket examples"
	@echo "  make verify                         Check submodules, snapshots, and empty renders"
	@echo "  make ci                             Run the complete CI suite"
	@echo ""
	@echo "$(CYAN)List:$(RESET)"
	@echo "  make list glyphs                   List available glyphs"
	@echo "  make list examples <name>          List examples for a glyph or summon"
	@echo "  make list books                    List available books"
	@echo ""

# ============================================================================
# Render
# ============================================================================

render:
	@command -v helm >/dev/null 2>&1 || { \
		echo "$(RED)$(BOLD)Error:$(RESET) helm is not installed or not in PATH"; \
		echo "Install: https://helm.sh/docs/intro/install/"; \
		exit 1; \
	}; \
	resource="$(RESOURCE)"; \
	name="$(NAME)"; \
	file="$(FILE)"; \
	case "$$resource" in \
	glyph) \
		if [ -z "$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Glyph name required"; \
			echo "Usage: make render glyph <name> [file]"; \
			echo "Available: $(GLYPHS)"; \
			exit 1; \
		fi; \
		if [ ! -d "$(GLYPHS_DIR)/$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Glyph '$$name' not found"; \
			echo "Available: $(GLYPHS)"; \
			exit 1; \
		fi; \
		if [ -n "$$file" ]; then \
			file="$${file%.yaml}.yaml"; \
			if [ ! -f "$(GLYPHS_DIR)/$$name/examples/$$file" ]; then \
				echo "$(RED)$(BOLD)Error:$(RESET) Example '$$file' not found for glyph '$$name'"; \
				echo "Available:"; ls -1 "$(GLYPHS_DIR)/$$name/examples/" 2>/dev/null; \
				exit 1; \
			fi; \
			echo "$(CYAN)$(BOLD)Rendering$(RESET) $$name/$$file"; \
			$(HELM_TEST) ./$(KASTER_DIR) -f "./$(GLYPHS_DIR)/$$name/examples/$$file"; \
		else \
			errors=0; \
			for f in $(GLYPHS_DIR)/$$name/examples/*.yaml; do \
				echo ""; \
				echo "$(CYAN)$(BOLD)Rendering$(RESET) $$name/$$(basename $$f)"; \
				echo "---"; \
				if ! $(HELM_TEST) ./$(KASTER_DIR) -f "$$f"; then errors=$$((errors + 1)); fi; \
			done; \
			if [ $$errors -gt 0 ]; then exit 1; fi; \
		fi; \
		;; \
	summon) \
		file="$$name"; \
		if [ -n "$$file" ]; then \
			file="$${file%.yaml}.yaml"; \
			if [ ! -f "$(SUMMON_DIR)/examples/$$file" ]; then \
				echo "$(RED)$(BOLD)Error:$(RESET) Example '$$file' not found for summon"; \
				echo "Available:"; ls -1 "$(SUMMON_DIR)/examples/" 2>/dev/null; \
				exit 1; \
			fi; \
			echo "$(CYAN)$(BOLD)Rendering$(RESET) summon/$$file"; \
			$(HELM_TEST) ./$(SUMMON_DIR) -f "./$(SUMMON_DIR)/examples/$$file"; \
		else \
			errors=0; \
			for f in $(SUMMON_DIR)/examples/*.yaml; do \
				echo ""; \
				echo "$(CYAN)$(BOLD)Rendering$(RESET) summon/$$(basename $$f)"; \
				echo "---"; \
				if ! $(HELM_TEST) ./$(SUMMON_DIR) -f "$$f"; then errors=$$((errors + 1)); fi; \
			done; \
			if [ $$errors -gt 0 ]; then exit 1; fi; \
		fi; \
		;; \
	book) \
		if [ -z "$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Book name required"; \
			echo "Usage: make render book <name>"; \
			echo "Available: $(BOOKS)"; \
			exit 1; \
		fi; \
		if ! grep -Fxq "$$name" $(LIBRARIAN_BOOKS_FILE); then \
			echo "$(RED)$(BOLD)Error:$(RESET) Book '$$name' is not a Librarian fixture"; \
			echo "Available: $(BOOKS)"; \
			exit 1; \
		fi; \
		echo "$(CYAN)$(BOLD)Rendering$(RESET) book/$$name"; \
		helm template "$$name" ./$(LIBRARIAN_DIR); \
		;; \
	_integration) \
		command -v yq >/dev/null 2>&1 || { \
			echo "$(RED)$(BOLD)Error:$(RESET) yq is required for integration tests"; \
			exit 1; \
		}; \
		tmp_dir=$$(mktemp -d); \
		trap 'rm -rf "$$tmp_dir"' EXIT; \
		assert_eq() { \
			expected="$$1"; actual="$$2"; label="$$3"; \
			if [ "$$actual" != "$$expected" ]; then \
				echo "  $(RED)FAIL$(RESET) $$label (expected '$$expected', got '$$actual')"; \
				return 1; \
			fi; \
			echo "  $(GREEN)PASS$(RESET) $$label"; \
		}; \
		render_source() { \
			app="$$1"; index="$$2"; chart="$$3"; label="$$4"; \
			APP="$$app" INDEX="$$index" yq -y \
				'select(.kind == "Application" and .metadata.name == env.APP) | .spec.sources[env.INDEX | tonumber].helm.valuesObject' \
				"$$tmp_dir/librarian.yaml" > "$$tmp_dir/$$label-values.yaml"; \
			$(HELM_TEST) "$$chart" -f "$$tmp_dir/$$label-values.yaml" > "$$tmp_dir/$$label.yaml"; \
			grep -q '^kind: ' "$$tmp_dir/$$label.yaml"; \
			echo "  $(GREEN)PASS$(RESET) $$label values render through $$chart"; \
		}; \
		echo "$(BOLD)Testing the realistic example book$(RESET)"; \
		assert_eq $$'https://github.com/runik-platform/runik.git\tlibrarian\tupstream' \
			"$$(yq -r '[.spec.source.repoURL, .spec.source.path, .spec.source.targetRevision] | @tsv' bookdeclaration.yaml)" \
			'bootstrap points to Librarian inside the aggregate Runik repository'; \
		assert_eq '../bookrack' "$$(readlink $(LIBRARIAN_DIR)/bookrack)" \
			'Librarian resolves the aggregate bookrack through its tracked symlink'; \
		helm template example-book ./$(LIBRARIAN_DIR) > "$$tmp_dir/librarian.yaml"; \
		assert_eq 'apply-branch-rules,cert-manager,console,covenant-example,keycloak,nightly-backup,pg-infra,public,saml,service,vault' \
			"$$(yq -s -r '[.[] | select(.kind == "Application") | .metadata.name] | sort | join(",")' "$$tmp_dir/librarian.yaml")" \
			'expected platform Applications are emitted'; \
		assert_eq '1' \
			"$$(yq -s -r '[.[] | select(.kind == "AppProject")] | length' "$$tmp_dir/librarian.yaml")" \
			'one AppProject is emitted'; \
		assert_eq 'https://kubernetes.default.svc' \
			"$$(yq -s -r '[.[] | select(.kind == "Application") | .spec.destination.server] | unique | join(",")' "$$tmp_dir/librarian.yaml")" \
			'development clusterSelector resolves for every spell'; \
		assert_eq '3' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "cert-manager") | .spec.sources | length' "$$tmp_dir/librarian.yaml")" \
			'cert-manager composes chart, ClusterIssuer glyph, and external-dns rune'; \
		assert_eq $$'https://charts.jetstack.io\tcert-manager\tv1.21.1\ttrue' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "cert-manager") | .spec.sources[0] | [.repoURL, .chart, .targetRevision, .helm.skipCrds] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'cert-manager primary source is preserved'; \
		assert_eq $$'https://github.com/runik-platform/kaster.git\t.\tupstream' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "cert-manager") | .spec.sources[1] | [.repoURL, .path, .targetRevision] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'Kaster uses its standalone GitHub repository'; \
		assert_eq 'chapter,glyphs,lexicon,spellbook' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "cert-manager") | .spec.sources[1].helm.valuesObject | keys | join(",")' "$$tmp_dir/librarian.yaml")" \
			'Kaster receives only glyphs and shared context'; \
		assert_eq 'clusterIssuer' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "cert-manager") | .spec.sources[1].helm.valuesObject.glyphs."cert-manager"."letsencrypt-staging".type' "$$tmp_dir/librarian.yaml")" \
			'cert-manager materializes the published issuer'; \
		assert_eq 'false' \
			"$$(yq -r '.appendix.lexicon | has("letsencrypt-staging")' ./$(BOOKRACK_DIR)/example-book/index.yaml)" \
			'book index contains only infrastructure without a producer spell'; \
		assert_eq $$'https://kubernetes-sigs.github.io/external-dns/\texternal-dns\t1.21.1' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "cert-manager") | .spec.sources[2] | [.repoURL, .chart, .targetRevision] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'external-dns remains an independent rune'; \
		assert_eq $$'https://github.com/runik-platform/microspell.git\t.\tupstream' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "console") | .spec.sources[0] | [.repoURL, .path, .targetRevision] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'services chapter selects standalone Microspell'; \
		assert_eq $$'ghcr.io/example\tv1.2.0' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "console") | .spec.sources[0].helm.valuesObject.image | [.repository, .tag] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'chapter image defaults merge with the console spell'; \
		assert_eq 'certificate' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "console") | .spec.sources[1].helm.valuesObject.glyphs."cert-manager"."console-tls".type' "$$tmp_dir/librarian.yaml")" \
			'console consumes the globally published issuer through Kaster'; \
		assert_eq $$'cluster\tpg-infra\tglobal' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "pg-infra") | .spec.sources[0].helm.valuesObject | [.postgresql."pg-infra".type, .lexicon."pg-infra".labels.name, .lexicon."pg-infra".labels.scope] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'pg-infra creates and globally publishes the shared cluster'; \
		assert_eq 'false' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "pg-infra") | .spec.sources[0].helm.valuesObject.postgresql."pg-infra".dbEngine.enabled' "$$tmp_dir/librarian.yaml")" \
			'pg-infra remains independent from the Vault instance that consumes it'; \
		assert_eq $$'db\tpg-infra\tglobal' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "vault") | .spec.sources[0].helm.valuesObject.postgresql.vault | [.type, .selector.name, .selector.scope] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'Vault consumes pg-infra through its published selector'; \
		assert_eq $$'secret-store\tglobal\tbook' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "pg-infra") | .spec.sources[0].helm.valuesObject.lexicon."development-vault" | [.type, .labels.scope, .labels."default"] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'Vault publishes its secret store to the rest of the book'; \
		assert_eq $$'db\tpg-infra\tglobal' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "keycloak") | .spec.sources[0].helm.valuesObject.postgresql.keycloak | [.type, .selector.name, .selector.scope] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'Keycloak consumes the globally published PostgreSQL service'; \
		assert_eq $$'https://github.com/runik-platform/runik.git\tcovenant\tupstream' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "covenant-example") | .spec.sources[0] | [.repoURL, .path, .targetRevision] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'Covenant is invoked through its aggregate-repository symlink'; \
		assert_eq '../bookrack' "$$(readlink $(COVENANT_DIR)/bookrack)" \
			'Covenant resolves the aggregate IAM book through its tracked symlink'; \
		assert_eq $$'https://github.com/runik-platform/runik.git\tcovenant\tupstream' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "covenant-example") | .spec.sources[0].helm.valuesObject.applicationSet.source | [.repository, .path, .revision] | @tsv' "$$tmp_dir/librarian.yaml")" \
			'Covenant principal shards reuse the aggregate repository source'; \
		assert_eq 'false' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "apply-branch-rules") | .spec.sources[0].helm.valuesObject | has("tarot")' "$$tmp_dir/librarian.yaml")" \
			'Tarot input is absent from the Summon source'; \
		assert_eq 'true' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "apply-branch-rules") | .spec.sources[0].helm.valuesObject | has("vault")' "$$tmp_dir/librarian.yaml")" \
			'Summon retains the workflow Vault declarations'; \
		assert_eq 'repository' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "apply-branch-rules") | .spec.sources[1].helm.valuesObject.chapter.tarot.cards."initialize-repository".contract.inputs.parameters | keys | join(",")' "$$tmp_dir/librarian.yaml")" \
			'chapter Tarot card contract reaches the workflow source'; \
		assert_eq 'default-branch' \
			"$$(yq -r 'select(.kind == "Application" and .metadata.name == "apply-branch-rules") | .spec.sources[1].helm.valuesObject.tarot.reading.cards.protection.depends | join(",")' "$$tmp_dir/librarian.yaml")" \
			'repository bootstrap dependencies survive composition'; \
		render_source cert-manager 1 ./$(KASTER_DIR) cert-manager-issuer; \
		render_source nightly-backup 0 ./$(SUMMON_DIR) nightly-backup; \
		render_source pg-infra 0 ./$(SUMMON_DIR) pg-infra; \
		render_source vault 0 ./$(SUMMON_DIR) vault-postgresql; \
		render_source keycloak 0 ./$(SUMMON_DIR) keycloak-postgresql; \
		render_source keycloak 1 ./$(KASTER_DIR) keycloak-provider; \
		render_source console 0 ./$(MICROSPELL_DIR) console; \
		render_source console 1 ./$(KASTER_DIR) console-certificate; \
		render_source public 0 ./$(MICROSPELL_DIR) public; \
		render_source saml 0 ./$(MICROSPELL_DIR) saml; \
		render_source service 0 ./$(MICROSPELL_DIR) service; \
		render_source apply-branch-rules 0 ./$(SUMMON_DIR) branch-rules-access; \
		render_source apply-branch-rules 1 ./$(TAROT_DIR) branch-rules-workflow; \
		APP=covenant-example yq -y \
			'select(.kind == "Application" and .metadata.name == env.APP) | .spec.sources[0].helm.valuesObject' \
			"$$tmp_dir/librarian.yaml" > "$$tmp_dir/covenant-from-librarian-values.yaml"; \
		helm template covenant-example ./$(COVENANT_DIR) --namespace covenant-example \
			-f "$$tmp_dir/covenant-from-librarian-values.yaml" > "$$tmp_dir/covenant-from-librarian.yaml"; \
		grep -q '^kind: ClusterKeycloakRealm$$' "$$tmp_dir/covenant-from-librarian.yaml"; \
		grep -q '^kind: ApplicationSet$$' "$$tmp_dir/covenant-from-librarian.yaml"; \
		echo "  $(GREEN)PASS$(RESET) Librarian values compile the Covenant IAM book and application contracts"; \
		;; \
	covenant) \
		echo "$(CYAN)$(BOLD)Rendering$(RESET) complete Covenant fixture"; \
		helm template covenant-example ./$(COVENANT_DIR) \
			--namespace covenant-example \
			-f tests/covenant/context.yaml; \
		;; \
	*) \
		echo "$(RED)$(BOLD)Error:$(RESET) Unknown resource '$$resource'"; \
		echo "Usage: make render {glyph <name> [file]|summon [file]|book <name>|covenant}"; \
		exit 1; \
		;; \
	esac

# ============================================================================
# Snapshot
# ============================================================================

snapshot:
	@command -v helm >/dev/null 2>&1 || { \
		echo "$(RED)$(BOLD)Error:$(RESET) helm is not installed or not in PATH"; \
		echo "Install: https://helm.sh/docs/intro/install/"; \
		exit 1; \
	}; \
	resource="$(RESOURCE)"; \
	name="$(NAME)"; \
	file="$(FILE)"; \
	case "$$resource" in \
	glyph) \
		if [ -z "$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Glyph name required"; \
			echo "Usage: make snapshot glyph <name> [file]"; \
			echo "Available: $(GLYPHS)"; \
			exit 1; \
		fi; \
		if [ ! -d "$(GLYPHS_DIR)/$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Glyph '$$name' not found"; \
			echo "Available: $(GLYPHS)"; \
			exit 1; \
		fi; \
		snap_dir="$(SNAPSHOTS_DIR)/glyphs/$$name"; \
		mkdir -p "$$snap_dir"; \
		if [ -n "$$file" ]; then \
			file="$${file%.yaml}.yaml"; \
			if [ ! -f "$(GLYPHS_DIR)/$$name/examples/$$file" ]; then \
				echo "$(RED)$(BOLD)Error:$(RESET) Example '$$file' not found for glyph '$$name'"; \
				echo "Available:"; ls -1 "$(GLYPHS_DIR)/$$name/examples/" 2>/dev/null; \
				exit 1; \
			fi; \
			echo "$(BOLD)Snapshot glyph:$(RESET) $$name"; \
			echo ""; \
			tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
			if $(HELM_TEST) ./$(KASTER_DIR) -f "$(GLYPHS_DIR)/$$name/examples/$$file" > "$$tmp"; then \
				mv "$$tmp" "$$snap_dir/$$file.snap"; \
				echo "  $(GREEN)SAVED$(RESET)  $$file"; \
			else \
				rm -f "$$tmp"; \
				echo "  $(RED)ERROR$(RESET)  $$file (render failed)"; \
				exit 1; \
			fi; \
		else \
			echo "$(BOLD)Snapshot glyph:$(RESET) $$name"; \
			echo ""; \
			saved=0; errors=0; \
			for f in $(GLYPHS_DIR)/$$name/examples/*.yaml; do \
				fname=$$(basename "$$f"); \
				tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
				if $(HELM_TEST) ./$(KASTER_DIR) -f "$$f" > "$$tmp"; then \
					mv "$$tmp" "$$snap_dir/$$fname.snap"; \
					echo "  $(GREEN)SAVED$(RESET)  $$fname"; \
					saved=$$((saved + 1)); \
				else \
					rm -f "$$tmp"; \
					echo "  $(RED)ERROR$(RESET)  $$fname (render failed)"; \
					errors=$$((errors + 1)); \
				fi; \
			done; \
			echo ""; \
			echo "$(BOLD)Results:$(RESET) $$saved saved, $$errors errors"; \
			if [ $$errors -gt 0 ]; then exit 1; fi; \
		fi; \
		;; \
	summon) \
		snap_dir="$(SNAPSHOTS_DIR)/summon"; \
		mkdir -p "$$snap_dir"; \
		file="$$name"; \
		if [ -n "$$file" ]; then \
			file="$${file%.yaml}.yaml"; \
			if [ ! -f "$(SUMMON_DIR)/examples/$$file" ]; then \
				echo "$(RED)$(BOLD)Error:$(RESET) Example '$$file' not found for summon"; \
				echo "Available:"; ls -1 "$(SUMMON_DIR)/examples/" 2>/dev/null; \
				exit 1; \
			fi; \
			echo "$(BOLD)Snapshot summon$(RESET)"; \
			echo ""; \
			tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
			if $(HELM_TEST) ./$(SUMMON_DIR) -f "$(SUMMON_DIR)/examples/$$file" > "$$tmp"; then \
				mv "$$tmp" "$$snap_dir/$$file.snap"; \
				echo "  $(GREEN)SAVED$(RESET)  $$file"; \
			else \
				rm -f "$$tmp"; \
				echo "  $(RED)ERROR$(RESET)  $$file (render failed)"; \
				exit 1; \
			fi; \
		else \
			echo "$(BOLD)Snapshot summon$(RESET)"; \
			echo ""; \
			saved=0; errors=0; \
			for f in $(SUMMON_DIR)/examples/*.yaml; do \
				fname=$$(basename "$$f"); \
				tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
				if $(HELM_TEST) ./$(SUMMON_DIR) -f "$$f" > "$$tmp"; then \
					mv "$$tmp" "$$snap_dir/$$fname.snap"; \
					echo "  $(GREEN)SAVED$(RESET)  $$fname"; \
					saved=$$((saved + 1)); \
				else \
					rm -f "$$tmp"; \
					echo "  $(RED)ERROR$(RESET)  $$fname (render failed)"; \
					errors=$$((errors + 1)); \
				fi; \
			done; \
			echo ""; \
			echo "$(BOLD)Results:$(RESET) $$saved saved, $$errors errors"; \
			if [ $$errors -gt 0 ]; then exit 1; fi; \
		fi; \
		;; \
	book) \
		if [ -z "$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Book name required"; \
			echo "Usage: make snapshot book <name>"; \
			echo "Available: $(BOOKS)"; \
			exit 1; \
		fi; \
		if ! grep -Fxq "$$name" $(LIBRARIAN_BOOKS_FILE); then \
			echo "$(RED)$(BOLD)Error:$(RESET) Book '$$name' is not a Librarian fixture"; \
			echo "Available: $(BOOKS)"; \
			exit 1; \
		fi; \
		snap_dir="$(SNAPSHOTS_DIR)/books"; \
		mkdir -p "$$snap_dir"; \
		echo "$(BOLD)Snapshot book:$(RESET) $$name"; \
		echo ""; \
		tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
		if helm template "$$name" ./$(LIBRARIAN_DIR) > "$$tmp"; then \
			mv "$$tmp" "$$snap_dir/$$name.yaml.snap"; \
			echo "  $(GREEN)SAVED$(RESET)  $$name"; \
		else \
			rm -f "$$tmp"; \
			echo "  $(RED)ERROR$(RESET)  $$name (render failed)"; \
			exit 1; \
		fi; \
		;; \
	all) \
		total_saved=0; total_errors=0; \
		echo "$(BOLD)Snapshot all glyphs + summon + books$(RESET)"; \
		echo "========================================"; \
		for glyph in $(GLYPHS); do \
			if [ ! -d "$(GLYPHS_DIR)/$$glyph/examples" ]; then continue; fi; \
			examples=$$(ls $(GLYPHS_DIR)/$$glyph/examples/*.yaml 2>/dev/null || true); \
			if [ -z "$$examples" ]; then continue; fi; \
			snap_dir="$(SNAPSHOTS_DIR)/glyphs/$$glyph"; \
			mkdir -p "$$snap_dir"; \
			echo ""; \
			echo "$(BOLD)$$glyph$(RESET)"; \
			for f in $$examples; do \
				fname=$$(basename "$$f"); \
				tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
				if $(HELM_TEST) ./$(KASTER_DIR) -f "$$f" > "$$tmp"; then \
					mv "$$tmp" "$$snap_dir/$$fname.snap"; \
					echo "  $(GREEN)SAVED$(RESET)  $$fname"; \
					total_saved=$$((total_saved + 1)); \
				else \
					rm -f "$$tmp"; \
					echo "  $(RED)ERROR$(RESET)  $$fname (render failed)"; \
					total_errors=$$((total_errors + 1)); \
				fi; \
			done; \
		done; \
		echo ""; \
		echo "$(BOLD)summon$(RESET)"; \
		snap_dir="$(SNAPSHOTS_DIR)/summon"; \
		mkdir -p "$$snap_dir"; \
		for f in $(SUMMON_DIR)/examples/*.yaml; do \
			fname=$$(basename "$$f"); \
			tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
			if $(HELM_TEST) ./$(SUMMON_DIR) -f "$$f" > "$$tmp"; then \
				mv "$$tmp" "$$snap_dir/$$fname.snap"; \
				echo "  $(GREEN)SAVED$(RESET)  $$fname"; \
				total_saved=$$((total_saved + 1)); \
			else \
				rm -f "$$tmp"; \
				echo "  $(RED)ERROR$(RESET)  $$fname (render failed)"; \
				total_errors=$$((total_errors + 1)); \
			fi; \
		done; \
		echo ""; \
		echo "$(BOLD)books$(RESET)"; \
		snap_dir="$(SNAPSHOTS_DIR)/books"; \
		mkdir -p "$$snap_dir"; \
		for book in $(BOOKS); do \
			tmp=$$(mktemp "$$snap_dir/.snapshot.XXXXXX"); \
			if helm template "$$book" ./$(LIBRARIAN_DIR) > "$$tmp"; then \
				mv "$$tmp" "$$snap_dir/$$book.yaml.snap"; \
				echo "  $(GREEN)SAVED$(RESET)  $$book"; \
				total_saved=$$((total_saved + 1)); \
			else \
				rm -f "$$tmp"; \
				echo "  $(RED)ERROR$(RESET)  $$book (render failed)"; \
				total_errors=$$((total_errors + 1)); \
			fi; \
		done; \
		echo ""; \
		echo "========================================"; \
		echo "$(BOLD)Total:$(RESET) $$total_saved saved, $$total_errors errors"; \
		if [ $$total_errors -gt 0 ]; then exit 1; fi; \
		;; \
	*) \
		echo "$(RED)$(BOLD)Error:$(RESET) Unknown resource '$$resource'"; \
		echo "Usage: make snapshot {glyph <name> [file]|summon [file]|book <name>|all}"; \
		exit 1; \
		;; \
	esac

# ============================================================================
# Test
# ============================================================================

test:
	@command -v helm >/dev/null 2>&1 || { \
		echo "$(RED)$(BOLD)Error:$(RESET) helm is not installed or not in PATH"; \
		echo "Install: https://helm.sh/docs/intro/install/"; \
		exit 1; \
	}; \
	resource="$(RESOURCE)"; \
	name="$(NAME)"; \
	file="$(FILE)"; \
	case "$$resource" in \
	glyph) \
		if [ -z "$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Glyph name required"; \
			echo "Usage: make test glyph <name> [file]"; \
			echo "Available: $(GLYPHS)"; \
			exit 1; \
		fi; \
		if [ ! -d "$(GLYPHS_DIR)/$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Glyph '$$name' not found"; \
			echo "Available: $(GLYPHS)"; \
			exit 1; \
		fi; \
		pass=0; fail=0; no_snap=0; \
		echo "$(BOLD)Testing glyph:$(RESET) $$name"; \
		echo ""; \
		if [ -n "$$file" ]; then \
			file="$${file%.yaml}.yaml"; \
			if [ ! -f "$(GLYPHS_DIR)/$$name/examples/$$file" ]; then \
				echo "$(RED)$(BOLD)Error:$(RESET) Example '$$file' not found for glyph '$$name'"; \
				echo "Available:"; ls -1 "$(GLYPHS_DIR)/$$name/examples/" 2>/dev/null; \
				exit 1; \
			fi; \
			files="$(GLYPHS_DIR)/$$name/examples/$$file"; \
		else \
			files="$(GLYPHS_DIR)/$$name/examples/*.yaml"; \
		fi; \
		for f in $$files; do \
			fname=$$(basename "$$f"); \
			snap="$(SNAPSHOTS_DIR)/glyphs/$$name/$$fname.snap"; \
			tmp=$$(mktemp); \
			if ! $(HELM_TEST) ./$(KASTER_DIR) -f "$$f" > "$$tmp"; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(render error)$(RESET)  $$fname"; \
				fail=$$((fail + 1)); \
			elif [ ! -f "$$snap" ]; then \
				echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$fname"; \
				fail=$$((fail + 1)); \
				no_snap=$$((no_snap + 1)); \
			elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$fname"; \
				diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
				fail=$$((fail + 1)); \
			else \
				echo "  $(GREEN)PASS$(RESET)  $$fname"; \
				pass=$$((pass + 1)); \
			fi; \
			rm -f "$$tmp"; \
		done; \
		echo ""; \
		echo "$(BOLD)Results:$(RESET) $$pass passed, $$fail failed"; \
		if [ $$no_snap -gt 0 ]; then \
			echo "$(YELLOW)Run 'make snapshot glyph $$name' to create missing snapshots$(RESET)"; \
		fi; \
		if [ $$fail -gt 0 ]; then exit 1; fi; \
		;; \
	summon) \
		pass=0; fail=0; no_snap=0; \
		echo "$(BOLD)Testing summon$(RESET)"; \
		echo ""; \
		file="$$name"; \
		if [ -n "$$file" ]; then \
			file="$${file%.yaml}.yaml"; \
			if [ ! -f "$(SUMMON_DIR)/examples/$$file" ]; then \
				echo "$(RED)$(BOLD)Error:$(RESET) Example '$$file' not found for summon"; \
				echo "Available:"; ls -1 "$(SUMMON_DIR)/examples/" 2>/dev/null; \
				exit 1; \
			fi; \
			files="$(SUMMON_DIR)/examples/$$file"; \
		else \
			files="$(SUMMON_DIR)/examples/*.yaml"; \
		fi; \
		for f in $$files; do \
			fname=$$(basename "$$f"); \
			snap="$(SNAPSHOTS_DIR)/summon/$$fname.snap"; \
			tmp=$$(mktemp); \
			if ! $(HELM_TEST) ./$(SUMMON_DIR) -f "$$f" > "$$tmp"; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(render error)$(RESET)  $$fname"; \
				fail=$$((fail + 1)); \
			elif [ ! -f "$$snap" ]; then \
				echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$fname"; \
				fail=$$((fail + 1)); \
				no_snap=$$((no_snap + 1)); \
			elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$fname"; \
				diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
				fail=$$((fail + 1)); \
			else \
				echo "  $(GREEN)PASS$(RESET)  $$fname"; \
				pass=$$((pass + 1)); \
			fi; \
			rm -f "$$tmp"; \
		done; \
		echo ""; \
		echo "$(BOLD)Results:$(RESET) $$pass passed, $$fail failed"; \
		if [ $$no_snap -gt 0 ]; then \
			echo "$(YELLOW)Run 'make snapshot summon' to create missing snapshots$(RESET)"; \
		fi; \
		if [ $$fail -gt 0 ]; then exit 1; fi; \
		;; \
	book) \
		if [ -z "$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Book name required"; \
			echo "Usage: make test book <name>"; \
			echo "Available: $(BOOKS)"; \
			exit 1; \
		fi; \
		if ! grep -Fxq "$$name" $(LIBRARIAN_BOOKS_FILE); then \
			echo "$(RED)$(BOLD)Error:$(RESET) Book '$$name' is not a Librarian fixture"; \
			echo "Available: $(BOOKS)"; \
			exit 1; \
		fi; \
		pass=0; fail=0; no_snap=0; \
		echo "$(BOLD)Testing book:$(RESET) $$name"; \
		echo ""; \
		snap="$(SNAPSHOTS_DIR)/books/$$name.yaml.snap"; \
		tmp=$$(mktemp); \
		if ! helm template "$$name" ./$(LIBRARIAN_DIR) > "$$tmp"; then \
			echo "  $(RED)FAIL$(RESET) $(RED)(render error)$(RESET)  $$name"; \
			fail=$$((fail + 1)); \
		elif [ ! -f "$$snap" ]; then \
			echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$name"; \
			fail=$$((fail + 1)); \
			no_snap=$$((no_snap + 1)); \
		elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
			echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$name"; \
			diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
			fail=$$((fail + 1)); \
		else \
			echo "  $(GREEN)PASS$(RESET)  $$name"; \
			pass=$$((pass + 1)); \
		fi; \
		rm -f "$$tmp"; \
		echo ""; \
		echo "$(BOLD)Results:$(RESET) $$pass passed, $$fail failed"; \
		if [ $$no_snap -gt 0 ]; then \
			echo "$(YELLOW)Run 'make snapshot book $$name' to create missing snapshots$(RESET)"; \
		fi; \
		if [ $$fail -gt 0 ]; then exit 1; fi; \
		;; \
	integration) \
		$(MAKE) --no-print-directory render _integration; \
		;; \
	covenant) \
		command -v yq >/dev/null 2>&1 || { \
			echo "$(RED)$(BOLD)Error:$(RESET) yq is required for Covenant tests"; \
			exit 1; \
		}; \
		tmp_dir=$$(mktemp -d); \
		trap 'rm -rf "$$tmp_dir"' EXIT; \
		echo "$(BOLD)Testing one complete Covenant instance$(RESET)"; \
		test "$$(yq -r 'has("dependencies")' ./$(COVENANT_DIR)/Chart.yaml)" = false; \
		test ! -e ./$(COVENANT_DIR)/Chart.lock; \
		cp tests/covenant/context.yaml "$$tmp_dir/context.yaml"; \
		helm template covenant-example ./$(COVENANT_DIR) \
			--namespace covenant-example \
			-f "$$tmp_dir/context.yaml" \
			--set-string name=covenant-example > "$$tmp_dir/covenant.yaml"; \
		: > "$$tmp_dir/principals.yaml"; \
		for shard in $$(yq -r 'select(.kind == "ApplicationSet") | .spec.generators[0].list.elements[].shard' "$$tmp_dir/covenant.yaml"); do \
			TEST_SHARD="$$shard" yq -y \
				'select(.kind == "ApplicationSet") | .spec.generators[0].list.elements[] | select(.shard == env.TEST_SHARD) | {"_covenant": {"manifests": .manifests}}' \
				"$$tmp_dir/covenant.yaml" > "$$tmp_dir/shard-$$shard.yaml"; \
			helm template "covenant-example-principals-$$shard" ./$(COVENANT_DIR) \
				--namespace covenant-example \
				-f "$$tmp_dir/shard-$$shard.yaml" \
				--set-string name=missing-book >> "$$tmp_dir/principals.yaml"; \
		done; \
		test "$$(awk '$$0 == "kind: Application" { count++ } END { print count + 0 }' "$$tmp_dir/covenant.yaml")" -eq 0; \
		test "$$(awk '$$0 == "kind: ApplicationSet" { count++ } END { print count + 0 }' "$$tmp_dir/covenant.yaml")" -eq 1; \
		test "$$(awk '$$0 == "kind: KeycloakRealmUser" { count++ } END { print count + 0 }' "$$tmp_dir/covenant.yaml")" -eq 0; \
		test "$$(awk '$$0 == "kind: KeycloakRealmUser" { count++ } END { print count + 0 }' "$$tmp_dir/principals.yaml")" -eq 3; \
		test "$$(awk '$$0 == "kind: KeycloakRealmGroup" { count++ } END { print count + 0 }' "$$tmp_dir/principals.yaml")" -eq 0; \
		test "$$(awk '$$0 == "kind: KeycloakClient" { count++ } END { print count + 0 }' "$$tmp_dir/principals.yaml")" -eq 0; \
		test "$$(yq -r 'has("_runik")' "$$tmp_dir/context.yaml")" = false; \
		test "$$(yq -r '.applicationSet.source.repository' "$$tmp_dir/context.yaml")" = https://github.com/runik-platform/covenant.git; \
		test "$$(yq -r '.applicationSet.source.path' "$$tmp_dir/context.yaml")" = .; \
		test "$$(yq -r 'select(.kind == "ApplicationSet") | .spec.generators[0].list.elements | length' "$$tmp_dir/covenant.yaml")" -eq 3; \
		test "$$(yq -r 'select(.kind == "ApplicationSet") | [.spec.generators[0].list.elements[] | .manifests | length > 0] | all' "$$tmp_dir/covenant.yaml")" = true; \
		test "$$(yq -r 'select(.kind == "ApplicationSet") | .spec.template.spec.source.helm.valuesObject | keys | join(",")' "$$tmp_dir/covenant.yaml")" = _covenant; \
		test "$$(yq -r 'select(.kind == "ApplicationSet") | .spec.template.spec.source.helm.valuesObject._covenant.manifests' "$$tmp_dir/covenant.yaml")" = '{{ .manifests }}'; \
		test "$$(yq -r 'select(.kind == "ApplicationSet") | .spec.template.spec.source.path' "$$tmp_dir/covenant.yaml")" = .; \
		test "$$(yq -r 'select(.kind == "ApplicationSet") | .spec.template.spec.syncPolicy.automated == {"prune": true, "selfHeal": true}' "$$tmp_dir/covenant.yaml")" = true; \
		test ! -e ./$(COVENANT_DIR)/renderer/Chart.yaml; \
		grep -q '^kind: KeycloakRealmIdentityProvider$$' "$$tmp_dir/covenant.yaml"; \
		grep -q '^kind: KeycloakAuthFlow$$' "$$tmp_dir/covenant.yaml"; \
		grep -q '^  name: github-idp$$' "$$tmp_dir/covenant.yaml"; \
		grep -q 'clientSecret: "\$$github-idp:client_secret"' "$$tmp_dir/covenant.yaml"; \
		grep -q '^kind: Certificate$$' "$$tmp_dir/covenant.yaml"; \
		test "$$(yq -r 'select(.kind == "Certificate" and .metadata.name == "saml-example-saml") | .metadata.namespace' "$$tmp_dir/covenant.yaml")" = saml; \
		test "$$(yq -r 'select(.kind == "Certificate" and .metadata.name == "saml-example-saml") | .spec.secretName' "$$tmp_dir/covenant.yaml")" = saml-example-saml-certificate; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.protocol == "saml") | .metadata.annotations."covenant.runik.io/certificate-secret"' "$$tmp_dir/covenant.yaml")" = saml/saml-example-saml-certificate; \
		grep -q 'username: kim.pyne@example.test' "$$tmp_dir/principals.yaml"; \
		grep -q 'username: hesh@example.test' "$$tmp_dir/principals.yaml"; \
		test "$$(yq -r 'select(.kind == "KeycloakRealmUser" and .spec.username == "kim.pyne@example.test") | .metadata.name' "$$tmp_dir/principals.yaml")" = kim-pyne; \
		test "$$(yq -r 'select(.kind == "KeycloakRealmUser" and .spec.username == "kim.pyne@example.test") | .metadata.annotations."covenant.runik.io/principal-ref"' "$$tmp_dir/principals.yaml")" = kim-pyne; \
		test "$$(yq -r 'select(.kind == "KeycloakRealmUser" and .spec.username == "kim.pyne@example.test") | .spec | has("requiredUserActions")' "$$tmp_dir/principals.yaml")" = false; \
		! grep -q 'clientId: console-other' "$$tmp_dir/covenant.yaml"; \
		! rg -q 'schemaVersion: covenant|providerRef: (keycloak|vault|certificates)|realmRef: (example|other)' \
			bookrack/covenant-example bookrack/example-book; \
		! rg -q '^(principals|groups|realmRoles|entitlements|packages|bindings|clientScopes|identityProviders|authenticationFlows):' \
			bookrack/covenant-example; \
		test "$$(yq -r 'select(.kind == "KeycloakRealmGroup" and .metadata.name == "engineering") | .spec.realmRoles | sort | join(",")' "$$tmp_dir/covenant.yaml")" = org-admin,user; \
		test "$$(yq -r 'select(.kind == "KeycloakRealmUser" and .spec.username == "kim.pyne@example.test") | .spec.groups | join(",")' "$$tmp_dir/principals.yaml")" = engineering; \
		grep -q '^      roleRef: engineering-member$$' "$$tmp_dir/covenant.yaml"; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.clientId == "console") | .spec.directAccess' "$$tmp_dir/covenant.yaml")" = false; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.clientId == "console") | .spec.standardFlowEnabled' "$$tmp_dir/covenant.yaml")" = true; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.clientId == "console") | .spec.attributes."oauth2.device.authorization.grant.enabled"' "$$tmp_dir/covenant.yaml")" = false; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.clientId == "console") | .spec.authorizationServicesEnabled' "$$tmp_dir/covenant.yaml")" = true; \
		test "$$(yq -r '.sources.applicationBooks | map(.name) | sort | join(",")' ./$(BOOKRACK_DIR)/covenant-example/index.yaml)" = example-book; \
		test "$$(awk '$$0 == "kind: KeycloakClient" { count++ } END { print count + 0 }' "$$tmp_dir/covenant.yaml")" -eq 4; \
		test "$$(yq -r 'select(.kind == "KeycloakRealmUser" and .spec.username == "kim.pyne@example.test") | .spec.clientRoles[] | select(.clientId == "console") | .roles | join(",")' "$$tmp_dir/principals.yaml")" = reader; \
		test "$$(yq -r 'select(.kind == "ClusterKeycloakRealm") | .spec.themes.adminConsoleTheme' "$$tmp_dir/covenant.yaml")" = keycloak.v2; \
		test "$$(yq -r 'select(.kind == "ClusterKeycloakRealm") | .spec.sessions.ssoSessionSettings.idleTimeout' "$$tmp_dir/covenant.yaml")" = 1800; \
		test "$$(yq -r 'select(.kind == "ClusterKeycloakRealm") | .spec.tokenSettings.revokeRefreshToken' "$$tmp_dir/covenant.yaml")" = false; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.clientId == "console") | .spec.webOrigins[0]' "$$tmp_dir/covenant.yaml")" = https://console.example.test; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.clientId == "console") | .spec.defaultClientScopes[0]' "$$tmp_dir/covenant.yaml")" = groups; \
		test "$$(yq -r 'select(.kind == "VaultSecret" and .metadata.name == "keycloak-client-console") | .spec.vaultSecretDefinitions[0].authentication.serviceAccount.name' "$$tmp_dir/covenant.yaml")" = console; \
		test "$$(yq -r 'select(.kind == "VaultSecret" and .metadata.name == "keycloak-client-console") | .spec.output.stringData.client_id' "$$tmp_dir/covenant.yaml")" = console; \
		test "$$(yq -r 'select(.kind == "VaultSecret" and .metadata.name == "keycloak-client-console") | .spec.output.stringData.client_secret' "$$tmp_dir/covenant.yaml")" = '{{ .secret.client_secret }}'; \
		test "$$(yq -r 'select(.kind == "RandomSecret" and .metadata.name == "principal-password-kim-pyne") | .spec.path' "$$tmp_dir/principals.yaml")" = secret/data/covenant/example/principals/; \
		test "$$(yq -r 'select(.kind == "RandomSecret" and .metadata.name == "principal-password-kim-pyne") | .spec.authentication.serviceAccount.name' "$$tmp_dir/principals.yaml")" = covenant-example-principals-k; \
		test "$$(yq -r 'select(.kind == "VaultSecret" and .metadata.name == "principal-password-kim-pyne") | .spec.vaultSecretDefinitions[0].path' "$$tmp_dir/principals.yaml")" = secret/data/covenant/example/principals/principal-password-kim-pyne; \
		yq -r 'select(.kind == "Policy" and .metadata.name == "covenant-example-principals-k") | .spec.policy' "$$tmp_dir/principals.yaml" | grep -q 'secret/data/covenant/example/principals/principal-password-kim-pyne'; \
		test "$$(yq -r 'select(.kind == "RandomSecret" and .metadata.name == "client-credentials-console-example") | .spec.path' "$$tmp_dir/covenant.yaml")" = secret/data/covenant/example/clients/; \
		test "$$(yq -r 'select(.kind == "VaultSecret" and .metadata.name == "client-credentials-console-example") | .spec.vaultSecretDefinitions[0].path' "$$tmp_dir/covenant.yaml")" = secret/data/covenant/example/clients/client-credentials-console-example; \
		yq -r 'select(.kind == "Policy" and .metadata.name == "covenant-console-example-console") | .spec.policy' "$$tmp_dir/covenant.yaml" | grep -q 'secret/data/covenant/example/clients/client-credentials-console-example'; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.clientId == "public") | .spec | has("secret")' "$$tmp_dir/covenant.yaml")" = false; \
		test "$$(yq -r 'select(.kind == "KeycloakClient" and .spec.protocol == "saml") | .spec | has("secret")' "$$tmp_dir/covenant.yaml")" = false; \
		test "$$(yq -r 'select(.kind == "ClusterKeycloakRealm") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "$$tmp_dir/covenant.yaml")" = 0; \
		test "$$(yq -r 'select(.kind == "KeycloakRealmUser" and .spec.username == "kim.pyne@example.test") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "$$tmp_dir/principals.yaml")" = 3; \
		echo "  $(GREEN)PASS$(RESET) one direct IAM compile with a deterministic principal ApplicationSet"; \
		echo "  $(GREEN)PASS$(RESET) glyphs vendored without Helm dependency metadata"; \
		echo "  $(GREEN)PASS$(RESET) RBAC, OIDC, SAML, IDP, auth flow, and application-contract scanning"; \
		cp -a ./$(COVENANT_DIR) "$$tmp_dir/covenant"; \
		cp -a ./$(BOOKRACK_DIR) "$$tmp_dir/bookrack"; \
		cp tests/covenant/alphabetical/assertions.tpl "$$tmp_dir/covenant/templates/alphabetical-test.yaml"; \
		principal_dir="$$tmp_dir/bookrack/covenant-example/identity/principals"; \
		for fixture in last-name display-name numeric-one numeric-nine; do \
			cp "tests/covenant/alphabetical/$$fixture.yaml" "$$principal_dir/$$fixture.yaml"; \
		done; \
		for scenario in baseline renamed added removed new-letter removed-letter; do \
			case "$$scenario" in \
				renamed) mv "$$principal_dir/last-name.yaml" "$$principal_dir/000-renamed.yaml" ;; \
				added) cp tests/covenant/alphabetical/add-same-letter.yaml "$$principal_dir/added.yaml" ;; \
				removed) mv "$$principal_dir/added.yaml" "$$tmp_dir/removed.yaml" ;; \
				new-letter) cp tests/covenant/alphabetical/add-new-letter.yaml "$$principal_dir/new-letter.yaml" ;; \
				removed-letter) mv "$$principal_dir/new-letter.yaml" "$$tmp_dir/removed-letter.yaml" ;; \
			esac; \
			helm template covenant-example "$$tmp_dir/covenant" --namespace covenant-example \
				-f "$$tmp_dir/context.yaml" \
				--set-string name=covenant-example > "$$tmp_dir/$$scenario.yaml"; \
			yq -S 'select(.kind == "ApplicationSet") | .spec.generators[0].list.elements | map({key: .shard, value: .manifests}) | from_entries' \
				"$$tmp_dir/$$scenario.yaml" > "$$tmp_dir/$$scenario.json"; \
		done; \
		for scenario in renamed removed removed-letter; do \
			cmp "$$tmp_dir/baseline.json" "$$tmp_dir/$$scenario.json"; \
		done; \
		yq -S 'del(.a)' "$$tmp_dir/baseline.json" > "$$tmp_dir/unaffected-before.json"; \
		yq -S 'del(.a)' "$$tmp_dir/added.json" > "$$tmp_dir/unaffected-after.json"; \
		cmp "$$tmp_dir/unaffected-before.json" "$$tmp_dir/unaffected-after.json"; \
		test "$$(yq -r '.a != null' "$$tmp_dir/added.json")" = true; \
		test "$$(yq -r '.a' "$$tmp_dir/added.json" | base64 --decode | yq -s -r '[.[] | select(.kind == "KeycloakRealmUser") | .spec.email] | join(",")')" = 'a.z@example.test,a0@example.test,aaron@example.test'; \
		test "$$(yq -r 'has("0-9")' "$$tmp_dir/baseline.json")" = true; \
		test "$$(yq -r 'has("z")' "$$tmp_dir/baseline.json")" = false; \
		test "$$(yq -r 'has("z")' "$$tmp_dir/new-letter.json")" = true; \
		yq -S 'del(.z)' "$$tmp_dir/new-letter.json" > "$$tmp_dir/without-new-letter.json"; \
		cmp "$$tmp_dir/baseline.json" "$$tmp_dir/without-new-letter.json"; \
		echo "  $(GREEN)PASS$(RESET) alphabetical grouping and stable payloads across book edits"; \
		;; \
	all) \
		total_pass=0; total_fail=0; total_no_snap=0; failed_list=""; \
		echo "$(BOLD)Testing all glyphs + summon + books$(RESET)"; \
		echo "========================================"; \
		for glyph in $(GLYPHS); do \
			if [ ! -d "$(GLYPHS_DIR)/$$glyph/examples" ]; then continue; fi; \
			examples=$$(ls $(GLYPHS_DIR)/$$glyph/examples/*.yaml 2>/dev/null || true); \
			if [ -z "$$examples" ]; then continue; fi; \
			pass=0; fail=0; \
			echo ""; \
			echo "$(BOLD)$$glyph$(RESET)"; \
			for f in $$examples; do \
				fname=$$(basename "$$f"); \
				snap="$(SNAPSHOTS_DIR)/glyphs/$$glyph/$$fname.snap"; \
				tmp=$$(mktemp); \
				if ! $(HELM_TEST) ./$(KASTER_DIR) -f "$$f" > "$$tmp"; then \
					echo "  $(RED)FAIL$(RESET) $(RED)(render error)$(RESET)  $$fname"; \
					fail=$$((fail + 1)); \
				elif [ ! -f "$$snap" ]; then \
					echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$fname"; \
					fail=$$((fail + 1)); \
					total_no_snap=$$((total_no_snap + 1)); \
				elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
					echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$fname"; \
					diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
					fail=$$((fail + 1)); \
				else \
					echo "  $(GREEN)PASS$(RESET)  $$fname"; \
					pass=$$((pass + 1)); \
				fi; \
				rm -f "$$tmp"; \
			done; \
			total_pass=$$((total_pass + pass)); \
			total_fail=$$((total_fail + fail)); \
			if [ $$fail -gt 0 ]; then \
				failed_list="$$failed_list $$glyph"; \
			fi; \
		done; \
		echo ""; \
		echo "$(BOLD)summon$(RESET)"; \
		for f in $(SUMMON_DIR)/examples/*.yaml; do \
			fname=$$(basename "$$f"); \
			snap="$(SNAPSHOTS_DIR)/summon/$$fname.snap"; \
			tmp=$$(mktemp); \
			if ! $(HELM_TEST) ./$(SUMMON_DIR) -f "$$f" > "$$tmp"; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(render error)$(RESET)  $$fname"; \
				total_fail=$$((total_fail + 1)); \
				if ! echo "$$failed_list" | grep -q "summon"; then \
					failed_list="$$failed_list summon"; \
				fi; \
			elif [ ! -f "$$snap" ]; then \
				echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$fname"; \
				total_fail=$$((total_fail + 1)); \
				total_no_snap=$$((total_no_snap + 1)); \
				if ! echo "$$failed_list" | grep -q "summon"; then \
					failed_list="$$failed_list summon"; \
				fi; \
			elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$fname"; \
				diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
				total_fail=$$((total_fail + 1)); \
				if ! echo "$$failed_list" | grep -q "summon"; then \
					failed_list="$$failed_list summon"; \
				fi; \
			else \
				echo "  $(GREEN)PASS$(RESET)  $$fname"; \
				total_pass=$$((total_pass + 1)); \
			fi; \
			rm -f "$$tmp"; \
		done; \
		echo ""; \
		echo "$(BOLD)books$(RESET)"; \
		for book in $(BOOKS); do \
			snap="$(SNAPSHOTS_DIR)/books/$$book.yaml.snap"; \
			tmp=$$(mktemp); \
			if ! helm template "$$book" ./$(LIBRARIAN_DIR) > "$$tmp"; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(render error)$(RESET)  $$book"; \
				total_fail=$$((total_fail + 1)); \
				if ! echo "$$failed_list" | grep -q "books"; then \
					failed_list="$$failed_list books"; \
				fi; \
			elif [ ! -f "$$snap" ]; then \
				echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$book"; \
				total_fail=$$((total_fail + 1)); \
				total_no_snap=$$((total_no_snap + 1)); \
				if ! echo "$$failed_list" | grep -q "books"; then \
					failed_list="$$failed_list books"; \
				fi; \
			elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$book"; \
				diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
				total_fail=$$((total_fail + 1)); \
				if ! echo "$$failed_list" | grep -q "books"; then \
					failed_list="$$failed_list books"; \
				fi; \
			else \
				echo "  $(GREEN)PASS$(RESET)  $$book"; \
				total_pass=$$((total_pass + 1)); \
			fi; \
			rm -f "$$tmp"; \
		done; \
		echo ""; \
		echo "========================================"; \
		echo "$(BOLD)Total:$(RESET) $$total_pass passed, $$total_fail failed"; \
		if [ -n "$$failed_list" ]; then \
			echo "$(RED)$(BOLD)Failed:$(RESET)$$failed_list"; \
		fi; \
		if [ $$total_no_snap -gt 0 ]; then \
			echo "$(YELLOW)Run 'make snapshot all' to create missing snapshots$(RESET)"; \
		fi; \
		if [ $$total_fail -gt 0 ]; then exit 1; fi; \
		;; \
	*) \
		echo "$(RED)$(BOLD)Error:$(RESET) Unknown resource '$$resource'"; \
		echo "Usage: make test {glyph <name> [file]|summon [file]|book <name>|integration|covenant|all}"; \
		exit 1; \
		;; \
	esac

# ============================================================================
# CI verification
# ============================================================================

verify:
	@for command in git helm make diff awk grep cmp mktemp yq rg; do \
		command -v "$$command" >/dev/null 2>&1 || { \
			echo "$(RED)$(BOLD)Error:$(RESET) $$command is required"; \
			exit 1; \
		}; \
	done; \
	tmp_dir=$$(mktemp -d); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	status=0; \
	submodule_status=$$(git submodule status --recursive); \
	if printf '%s\n' "$$submodule_status" | grep -Eq '^[-+U]'; then \
		echo "$(RED)$(BOLD)Submodule checkout mismatch:$(RESET)"; \
		printf '%s\n' "$$submodule_status"; \
		status=1; \
	else \
		echo "$(GREEN)PASS$(RESET) all submodules are initialized at their pinned commits"; \
	fi; \
	dirty_submodules=$$(git submodule foreach --quiet --recursive 'if [ -n "$$(git status --porcelain)" ]; then printf "%s\n" "$$displaypath"; fi'); \
	if [ -n "$$dirty_submodules" ]; then \
		echo "$(RED)$(BOLD)Dirty submodules:$(RESET)"; \
		printf '%s\n' "$$dirty_submodules"; \
		status=1; \
	else \
		echo "$(GREEN)PASS$(RESET) all submodule worktrees are clean"; \
	fi; \
	canonical_glyphs=$$(git -C $(GLYPHS_DIR) rev-parse HEAD); \
	for mirror in $(KASTER_DIR)/charts $(SUMMON_DIR)/charts $(MICROSPELL_DIR)/charts $(TAROT_DIR)/charts $(COVENANT_DIR)/charts; do \
		mirror_glyphs=$$(git -C "$$mirror" rev-parse HEAD); \
		if [ "$$mirror_glyphs" != "$$canonical_glyphs" ]; then \
			echo "$(RED)FAIL$(RESET) $$mirror is at $$mirror_glyphs, expected $$canonical_glyphs"; \
			status=1; \
		fi; \
	done; \
	if [ $$status -eq 0 ]; then \
		echo "$(GREEN)PASS$(RESET) every glyph mirror matches the canonical checkout"; \
	fi; \
	find $(BOOKRACK_DIR) -mindepth 2 -maxdepth 2 -type f -name index.yaml -printf '%h\n' | sed 's|.*/||' | sort -u > "$$tmp_dir/all-books"; \
	cat $(LIBRARIAN_BOOKS_FILE) $(COVENANT_APPLICATION_BOOKS_FILE) $(COVENANT_IAM_BOOKS_FILE) | grep -Ev '^[[:space:]]*(#|$$)' | sort -u > "$$tmp_dir/classified-books"; \
	if ! diff -u "$$tmp_dir/all-books" "$$tmp_dir/classified-books"; then \
		echo "$(RED)FAIL$(RESET) every bookrack fixture must have an explicit test role"; \
		status=1; \
	else \
		echo "$(GREEN)PASS$(RESET) every bookrack fixture has an explicit test role"; \
	fi; \
	yq -r '.sources.applicationBooks[].name' $(BOOKRACK_DIR)/covenant-example/index.yaml | sort -u > "$$tmp_dir/covenant-references"; \
	printf '%s\n' $(COVENANT_APPLICATION_BOOKS) | sort -u > "$$tmp_dir/covenant-books"; \
	if ! diff -u "$$tmp_dir/covenant-books" "$$tmp_dir/covenant-references"; then \
		echo "$(RED)FAIL$(RESET) Covenant application-book inventory differs from its IAM fixture"; \
		status=1; \
	else \
		echo "$(GREEN)PASS$(RESET) Covenant application-book inventory is exact"; \
	fi; \
	printf '%s\n' $(BOOKS) | sort -u > "$$tmp_dir/librarian-books"; \
	if ! comm -23 "$$tmp_dir/covenant-books" "$$tmp_dir/librarian-books" | grep -q .; then \
		echo "$(GREEN)PASS$(RESET) every Covenant application source is a Librarian fixture"; \
	else \
		echo "$(RED)FAIL$(RESET) Covenant application sources must be deployable Librarian fixtures"; \
		comm -23 "$$tmp_dir/covenant-books" "$$tmp_dir/librarian-books"; \
		status=1; \
	fi; \
	printf '%s\n' $(COVENANT_IAM_BOOKS) | sort -u > "$$tmp_dir/covenant-iam-books"; \
	if comm -12 "$$tmp_dir/covenant-iam-books" "$$tmp_dir/librarian-books" | grep -q .; then \
		echo "$(RED)FAIL$(RESET) Covenant IAM inputs must not be Librarian fixtures"; \
		comm -12 "$$tmp_dir/covenant-iam-books" "$$tmp_dir/librarian-books"; \
		status=1; \
	else \
		echo "$(GREEN)PASS$(RESET) Covenant IAM inputs are not Librarian fixtures"; \
	fi; \
	redundant_indexes=0; \
	while IFS= read -r index; do \
		if [ "$$(yq -r 'keys | sort | join(",")' "$$index")" = name ]; then \
			echo "$(RED)FAIL$(RESET) redundant chapter index contains only name: $$index"; \
			redundant_indexes=1; \
			status=1; \
		fi; \
	done < <(find $(BOOKRACK_DIR) -mindepth 3 -maxdepth 3 -type f -name index.yaml | sort); \
	if [ $$redundant_indexes -eq 0 ]; then \
		echo "$(GREEN)PASS$(RESET) chapter indexes contain real chapter configuration"; \
	fi; \
	for book in $(COVENANT_IAM_BOOKS); do \
		if [ "$$(yq -r 'has("chapters")' "$(BOOKRACK_DIR)/$$book/index.yaml")" != false ]; then \
			echo "$(RED)FAIL$(RESET) Covenant IAM input $$book must not define Librarian chapters"; \
			status=1; \
		fi; \
		definition_count=$$(find "$(BOOKRACK_DIR)/$$book" -type f -name '*.yaml' ! -name index.yaml | wc -l); \
		if [ "$$definition_count" -eq 0 ]; then \
			echo "$(RED)FAIL$(RESET) Covenant IAM book $$book must contain definitions outside index.yaml"; \
			status=1; \
		fi; \
	done; \
	for fixture in $(GLYPHS_DIR)/*/examples/*.yaml; do \
		glyph=$${fixture#$(GLYPHS_DIR)/}; glyph=$${glyph%%/*}; \
		printf '$(SNAPSHOTS_DIR)/glyphs/%s/%s.snap\n' "$$glyph" "$$(basename "$$fixture")"; \
	done | sort -u > "$$tmp_dir/expected-glyphs"; \
	find $(SNAPSHOTS_DIR)/glyphs -type f -name '*.yaml.snap' -print | sort -u > "$$tmp_dir/actual-glyphs"; \
	for fixture in $(SUMMON_DIR)/examples/*.yaml; do \
		printf '$(SNAPSHOTS_DIR)/summon/%s.snap\n' "$$(basename "$$fixture")"; \
	done | sort -u > "$$tmp_dir/expected-summon"; \
	find $(SNAPSHOTS_DIR)/summon -maxdepth 1 -type f -name '*.yaml.snap' -print | sort -u > "$$tmp_dir/actual-summon"; \
	for book in $(BOOKS); do \
		printf '$(SNAPSHOTS_DIR)/books/%s.yaml.snap\n' "$$book"; \
	done | sort -u > "$$tmp_dir/expected-books"; \
	find $(SNAPSHOTS_DIR)/books -maxdepth 1 -type f -name '*.yaml.snap' -print | sort -u > "$$tmp_dir/actual-books"; \
	for resource in glyphs summon books; do \
		if ! diff -u "$$tmp_dir/expected-$$resource" "$$tmp_dir/actual-$$resource"; then \
			echo "$(RED)FAIL$(RESET) $$resource snapshot inventory differs from its fixtures"; \
			status=1; \
		else \
			echo "$(GREEN)PASS$(RESET) $$resource snapshots have no missing or orphaned files"; \
		fi; \
	done; \
	if [ $$status -gt 0 ]; then exit 1; fi

smoke:
	@command -v helm >/dev/null 2>&1 || { \
		echo "$(RED)$(BOLD)Error:$(RESET) helm is not installed or not in PATH"; \
		exit 1; \
	}; \
	tmp_dir=$$(mktemp -d); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	failures=0; \
	check_chart() { \
		label="$$1"; chart="$$2"; examples="$$3"; \
		for fixture in "$$examples"/*.yaml; do \
			output="$$tmp_dir/$${label}-$$(basename "$$fixture")"; \
			if ! $(HELM_TEST) "$$chart" -f "$$fixture" > "$$output"; then \
				echo "  $(RED)FAIL$(RESET) $$label/$$(basename "$$fixture") (render error)"; \
				failures=$$((failures + 1)); \
			elif ! grep -q '^kind: ' "$$output"; then \
				echo "  $(RED)FAIL$(RESET) $$label/$$(basename "$$fixture") (no resources)"; \
				failures=$$((failures + 1)); \
			else \
				echo "  $(GREEN)PASS$(RESET) $$label/$$(basename "$$fixture")"; \
			fi; \
		done; \
	}; \
	echo "$(BOLD)Rendering aggregate chart examples$(RESET)"; \
	check_chart kaster ./$(KASTER_DIR) ./$(KASTER_DIR)/examples; \
	check_chart microspell ./$(MICROSPELL_DIR) ./$(MICROSPELL_DIR)/examples; \
	check_chart tarot ./$(TAROT_DIR) ./$(TAROT_DIR)/examples; \
	: > "$$tmp_dir/actual-empty"; \
	for fixture in $(GLYPHS_DIR)/*/examples/*.yaml; do \
		glyph=$${fixture#$(GLYPHS_DIR)/}; glyph=$${glyph%%/*}; \
		output="$$tmp_dir/glyph-$${glyph}-$$(basename "$$fixture")"; \
		if ! $(HELM_TEST) ./$(KASTER_DIR) -f "$$fixture" > "$$output"; then \
			echo "  $(RED)FAIL$(RESET) glyphs/$$glyph/$$(basename "$$fixture") (render error)"; \
			failures=$$((failures + 1)); \
		elif ! grep -q '^kind: ' "$$output"; then \
			printf '%s/%s\n' "$$glyph" "$$(basename "$$fixture")" >> "$$tmp_dir/actual-empty"; \
		fi; \
	done; \
	sort -u "$$tmp_dir/actual-empty" -o "$$tmp_dir/actual-empty"; \
	grep -Ev '^[[:space:]]*(#|$$)' $(KNOWN_EMPTY_FIXTURES) | sort -u > "$$tmp_dir/known-empty"; \
	if ! diff -u "$$tmp_dir/known-empty" "$$tmp_dir/actual-empty"; then \
		echo "$(RED)FAIL$(RESET) known-empty glyph fixtures changed"; \
		failures=$$((failures + 1)); \
	else \
		echo "$(GREEN)PASS$(RESET) empty glyph renders match the explicit allowlist"; \
	fi; \
	if [ $$failures -gt 0 ]; then exit 1; fi

ci: verify
	@$(MAKE) --no-print-directory smoke
	@$(MAKE) --no-print-directory test all
	@$(MAKE) --no-print-directory test integration
	@$(MAKE) --no-print-directory test covenant

# ============================================================================
# List
# ============================================================================

list:
	@resource="$(RESOURCE)"; \
	name="$(NAME)"; \
	case "$$resource" in \
	glyphs) \
		echo "$(BOLD)Available glyphs:$(RESET)"; \
		count=0; \
		for g in $(GLYPHS); do \
			n=$$(ls "$(GLYPHS_DIR)/$$g/examples/"*.yaml 2>/dev/null | wc -l); \
			echo "  $$g ($$n examples)"; \
			count=$$((count + 1)); \
		done; \
		echo ""; \
		echo "$(BOLD)Total:$(RESET) $$count glyphs"; \
		;; \
	examples) \
		if [ -z "$$name" ]; then \
			echo "$(RED)$(BOLD)Error:$(RESET) Name required"; \
			echo "Usage: make list examples <name>"; \
			echo "Use a glyph name or 'summon'"; \
			exit 1; \
		fi; \
		if [ "$$name" = "summon" ]; then \
			dir="$(SUMMON_DIR)/examples"; \
		elif [ -d "$(GLYPHS_DIR)/$$name/examples" ]; then \
			dir="$(GLYPHS_DIR)/$$name/examples"; \
		else \
			echo "$(RED)$(BOLD)Error:$(RESET) '$$name' not found"; \
			echo "Available glyphs: $(GLYPHS)"; \
			echo "Or use 'summon' for summon examples"; \
			exit 1; \
		fi; \
		echo "$(BOLD)Examples for $$name:$(RESET)"; \
		count=0; \
		for f in $$dir/*.yaml; do \
			echo "  $$(basename $$f)"; \
			count=$$((count + 1)); \
		done; \
		echo ""; \
		echo "$(BOLD)Total:$(RESET) $$count examples"; \
		;; \
	books) \
		echo "$(BOLD)Deployable Librarian fixtures:$(RESET)"; \
		count=0; \
		for b in $(BOOKS); do \
			echo "  $$b"; \
			count=$$((count + 1)); \
		done; \
		echo ""; \
		echo "$(BOLD)Total:$(RESET) $$count books"; \
		;; \
	*) \
		echo "$(RED)$(BOLD)Error:$(RESET) Unknown resource '$$resource'"; \
		echo "Usage: make list {glyphs|examples <name>|books}"; \
		exit 1; \
		;; \
	esac
