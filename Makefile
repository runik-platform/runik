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
GLYPHS_DIR     ?= charts/glyphs
SUMMON_DIR     := charts/summon
MICROSPELL_DIR := charts/trinkets/microspell
TAROT_DIR      := charts/trinkets/tarot
LIBRARIAN_DIR  := librarian
COVENANT_DIR   := covenant
GLYPH_MIRRORS := $(KASTER_DIR)/charts $(SUMMON_DIR)/charts $(MICROSPELL_DIR)/charts $(TAROT_DIR)/charts $(COVENANT_DIR)/charts
BOOKRACK_DIR   := bookrack
SNAPSHOTS_DIR  := tests/snapshots
KNOWN_EMPTY_FIXTURES := tests/known-empty-fixtures.txt
LIBRARIAN_BOOKS_FILE := tests/librarian-books.txt
COVENANT_APPLICATION_BOOKS_FILE := tests/covenant-application-books.txt
COVENANT_IAM_BOOKS_FILE := tests/covenant-iam-books.txt

TEST_RELEASE   ?= test
TEST_NAMESPACE ?= glyphs-release
HELM_TEST      := helm template $(TEST_RELEASE) --namespace $(TEST_NAMESPACE)
PROMTOOL       ?= promtool

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

.PHONY: help render test snapshot list verify smoke check-glyph-names test-glyph-name-checker test-glyph-contracts test-postgresql-observability test-autoscaling test-librarian test-component-candidate prepare-component-candidate verify-component-candidate ci ci-component-candidate ci-glyphs-candidate
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
	@echo "  make check-glyph-names              Reject duplicate Glyph chart/template names"
	@echo "  make test-glyph-name-checker        Test the global-name checker"
	@echo "  make test-glyph-contracts           Test cross-consumer Glyph contracts"
	@echo "  make test-postgresql-observability  Test PostgreSQL dashboards, alerts and PromQL"
	@echo "  make test-autoscaling               Test Summon and Microspell scaling modes"
	@echo "  make test-librarian                 Test Librarian source contracts"
	@echo "  make test-component-candidate       Test prospective Glyph dependency preparation"
	@echo "  make ci                             Run the complete CI suite"
	@echo "  make ci-component-candidate COMPONENT=<name>"
	@echo "                                      Test a prospective Runik component"
	@echo "  make ci-glyphs-candidate            Compatibility alias for COMPONENT=glyphs"
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
		while IFS= read -r snapshot; do \
			relative=$${snapshot#$(SNAPSHOTS_DIR)/glyphs/}; \
			glyph=$${relative%%/*}; fixture=$${relative#*/}; \
			if [ ! -f "$(GLYPHS_DIR)/$$glyph/examples/$${fixture%.snap}" ]; then \
				rm -- "$$snapshot"; \
				echo "  $(YELLOW)REMOVED$(RESET)  $$relative (fixture removed)"; \
			fi; \
		done < <(find "$(SNAPSHOTS_DIR)/glyphs" -type f -name '*.yaml.snap' | sort); \
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
		principals_policy=$$(yq -r 'select(.kind == "Policy" and .metadata.name == "covenant-example-principals-k") | .spec.policy' "$$tmp_dir/principals.yaml"); \
		grep -Fq 'secret/data/covenant/example/principals/principal-password-kim-pyne' <<< "$$principals_policy"; \
		test "$$(yq -r 'select(.kind == "RandomSecret" and .metadata.name == "client-credentials-console-example") | .spec.path' "$$tmp_dir/covenant.yaml")" = secret/data/covenant/example/clients/; \
		test "$$(yq -r 'select(.kind == "VaultSecret" and .metadata.name == "client-credentials-console-example") | .spec.vaultSecretDefinitions[0].path' "$$tmp_dir/covenant.yaml")" = secret/data/covenant/example/clients/client-credentials-console-example; \
		client_policy=$$(yq -r 'select(.kind == "Policy" and .metadata.name == "covenant-console-example-console") | .spec.policy' "$$tmp_dir/covenant.yaml"); \
		grep -Fq 'secret/data/covenant/example/clients/client-credentials-console-example' <<< "$$client_policy"; \
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
		test "$$(yq -r '.a' "$$tmp_dir/added.json" | base64 -d | yq -s -r '[.[] | select(.kind == "KeycloakRealmUser") | .spec.email] | join(",")')" = 'a.z@example.test,a0@example.test,aaron@example.test'; \
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
				if ! grep -Fq "summon" <<< "$$failed_list"; then \
					failed_list="$$failed_list summon"; \
				fi; \
			elif [ ! -f "$$snap" ]; then \
				echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$fname"; \
				total_fail=$$((total_fail + 1)); \
				total_no_snap=$$((total_no_snap + 1)); \
				if ! grep -Fq "summon" <<< "$$failed_list"; then \
					failed_list="$$failed_list summon"; \
				fi; \
			elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$fname"; \
				diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
				total_fail=$$((total_fail + 1)); \
				if ! grep -Fq "summon" <<< "$$failed_list"; then \
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
				if ! grep -Fq "books" <<< "$$failed_list"; then \
					failed_list="$$failed_list books"; \
				fi; \
			elif [ ! -f "$$snap" ]; then \
				echo "  $(RED)FAIL$(RESET) $(YELLOW)(no snapshot)$(RESET)   $$book"; \
				total_fail=$$((total_fail + 1)); \
				total_no_snap=$$((total_no_snap + 1)); \
				if ! grep -Fq "books" <<< "$$failed_list"; then \
					failed_list="$$failed_list books"; \
				fi; \
			elif ! diff -q "$$snap" "$$tmp" >/dev/null 2>&1; then \
				echo "  $(RED)FAIL$(RESET) $(RED)(changed)$(RESET)       $$book"; \
				diff --color=auto "$$snap" "$$tmp" | head -20 || true; \
				total_fail=$$((total_fail + 1)); \
				if ! grep -Fq "books" <<< "$$failed_list"; then \
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
	find $(BOOKRACK_DIR) -mindepth 2 -maxdepth 2 -type f -name index.yaml -print \
		| sed 's|/[^/]*$$||; s|.*/||' | sort -u > "$$tmp_dir/all-books"; \
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
	comm -23 "$$tmp_dir/covenant-books" "$$tmp_dir/librarian-books" > "$$tmp_dir/missing-covenant-books"; \
	if [ ! -s "$$tmp_dir/missing-covenant-books" ]; then \
		echo "$(GREEN)PASS$(RESET) every Covenant application source is a Librarian fixture"; \
	else \
		echo "$(RED)FAIL$(RESET) Covenant application sources must be deployable Librarian fixtures"; \
		cat "$$tmp_dir/missing-covenant-books"; \
		status=1; \
	fi; \
	printf '%s\n' $(COVENANT_IAM_BOOKS) | sort -u > "$$tmp_dir/covenant-iam-books"; \
	comm -12 "$$tmp_dir/covenant-iam-books" "$$tmp_dir/librarian-books" > "$$tmp_dir/overlapping-covenant-books"; \
	if [ -s "$$tmp_dir/overlapping-covenant-books" ]; then \
		echo "$(RED)FAIL$(RESET) Covenant IAM inputs must not be Librarian fixtures"; \
		cat "$$tmp_dir/overlapping-covenant-books"; \
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

check-glyph-names:
	@command -v rg >/dev/null 2>&1 || { \
		echo "$(RED)$(BOLD)Error:$(RESET) ripgrep (rg) is required" >&2; \
		exit 1; \
	}; \
	rg --pcre2-version >/dev/null 2>&1 || { \
		echo "$(RED)$(BOLD)Error:$(RESET) ripgrep must include PCRE2 support" >&2; \
		exit 1; \
	}; \
	root="$(abspath $(GLYPHS_DIR))"; \
	definitions=$$(mktemp); \
	charts=$$(mktemp); \
	matches=$$(mktemp); \
	trap 'rm -f "$$definitions" "$$charts" "$$matches"' EXIT; \
	chart_count=0; \
	for chart in "$$root"/*/Chart.yaml; do \
		test -f "$$chart" || continue; \
		chart_count=$$((chart_count + 1)); \
		chart_name=$$(awk '$$1 == "name:" { print $$2; exit }' "$$chart"); \
		if [ -z "$$chart_name" ]; then \
			echo "ERROR: Chart name missing from $$chart" >&2; \
			exit 1; \
		fi; \
		printf '%s\t%s\n' "$$chart_name" "$$chart" >> "$$charts"; \
		templates="$${chart%/Chart.yaml}/templates"; \
		test -d "$$templates" || continue; \
		rg --multiline --pcre2 --no-heading --line-number --only-matching \
			'(?s)\{\{-?\s*(?:define|block)\s+"\K[^"]+' "$$templates" \
			>> "$$matches" || true; \
	done; \
	if [ "$$chart_count" -eq 0 ]; then \
		echo "ERROR: no Glyph charts found below $$root" >&2; \
		exit 1; \
	fi; \
	sed -nE \
		's~^([^:]+):([0-9]+):(.*)$$~\3\t\1:\2~p' \
		"$$matches" | sort -k1,1 > "$$definitions"; \
	duplicate_templates=$$(cut -f1 "$$definitions" | uniq -d); \
	if [ -n "$$duplicate_templates" ]; then \
		echo "Duplicate Helm named templates:" >&2; \
		while IFS= read -r template; do \
			awk -F '\t' -v template="$$template" \
				'$$1 == template { print "  " $$0 }' "$$definitions" >&2; \
		done <<< "$$duplicate_templates"; \
		exit 1; \
	fi; \
	sort -k1,1 "$$charts" -o "$$charts"; \
	duplicate_charts=$$(cut -f1 "$$charts" | uniq -d); \
	if [ -n "$$duplicate_charts" ]; then \
		echo "Duplicate Glyph chart names:" >&2; \
		while IFS= read -r chart_name; do \
			awk -F '\t' -v chart_name="$$chart_name" \
				'$$1 == chart_name { print "  " $$0 }' "$$charts" >&2; \
		done <<< "$$duplicate_charts"; \
		exit 1; \
	fi; \
	echo "$(GREEN)PASS$(RESET) $$(wc -l < "$$definitions") Helm named templates are globally unique"; \
	echo "$(GREEN)PASS$(RESET) $$chart_count Glyph chart names are unique"

test-glyph-name-checker:
	@logs=$$(mktemp -d); \
	trap 'rm -rf "$$logs"' EXIT; \
	$(MAKE) --no-print-directory check-glyph-names \
		GLYPHS_DIR=tests/glyph-name-checker/unique > "$$logs/unique"; \
	for fixture in duplicate-template define-vs-block; do \
		if $(MAKE) --no-print-directory check-glyph-names \
			GLYPHS_DIR="tests/glyph-name-checker/$$fixture" > "$$logs/$$fixture" 2>&1; then \
			echo "$(RED)FAIL$(RESET) $$fixture was accepted" >&2; \
			exit 1; \
		fi; \
		rg -Fq 'Duplicate Helm named templates:' "$$logs/$$fixture"; \
	done; \
	if $(MAKE) --no-print-directory check-glyph-names \
		GLYPHS_DIR=tests/glyph-name-checker/duplicate-chart > "$$logs/duplicate-chart" 2>&1; then \
		echo "$(RED)FAIL$(RESET) duplicate-chart was accepted" >&2; \
		exit 1; \
	fi; \
	rg -Fq 'Duplicate Glyph chart names:' "$$logs/duplicate-chart"; \
	echo "$(GREEN)PASS$(RESET) global name checker accepts unique fixtures"; \
	echo "$(GREEN)PASS$(RESET) global name checker rejects duplicate define, block, and chart names"

test-postgresql-observability:
	@for tool in helm yq jq; do command -v "$$tool" >/dev/null; done; \
	tmp_dir=$$(mktemp -d); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	promtool="$(PROMTOOL)"; \
	if ! command -v "$$promtool" >/dev/null 2>&1; then \
		[ "$$promtool" = promtool ] || { echo "PROMTOOL executable not found: $$promtool" >&2; exit 1; }; \
		os=$$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$$(uname -m); \
		case "$$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac; \
		case "$$os-$$arch" in \
			linux-amd64) checksum=e811827af26d822afb09a4f28314f61b618b12cff5369835a67f674d8b46f39a ;; \
			linux-arm64) checksum=173389cc42bf09c4e6e54cb53fa07a5a835d7c261e14775d2183181d6e385d1c ;; \
			darwin-amd64) checksum=5856d0c306e7d852d9a79788b20acb630501b3fab120b69f5317d6b0732dea57 ;; \
			darwin-arm64) checksum=c17bc2c992f0b5515eebe2b4ccd626214f8e309a0fe6ec40ed13c42ec13d05fb ;; \
			*) echo "Set PROMTOOL to an installed executable on $$os-$$arch" >&2; exit 1 ;; \
		esac; \
		archive="prometheus-3.5.0.$$os-$$arch"; \
		wget -q -O "$$tmp_dir/prometheus.tar.gz" "https://github.com/prometheus/prometheus/releases/download/v3.5.0/$$archive.tar.gz"; \
		printf '%s  %s\n' "$$checksum" "$$tmp_dir/prometheus.tar.gz" | sha256sum -c -; \
		tar -xzf "$$tmp_dir/prometheus.tar.gz" -C "$$tmp_dir" "$$archive/promtool"; \
		promtool="$$tmp_dir/$$archive/promtool"; \
	fi; \
	fixture=tests/glyph-contracts/postgresql; \
	yq -y '.postgresql = .glyphs.postgresql | del(.glyphs) | .workload.enabled = false' \
		"$$fixture/observability.yaml" > "$$tmp_dir/summon.yaml"; \
	yq '.' "$$fixture/prometheus.yaml" > "$$tmp_dir/cases.json"; \
	for namespace in tenant-blue tenant-red; do \
		for consumer in kaster summon; do \
			chart="$(KASTER_DIR)"; values="$$fixture/observability.yaml"; \
			if [ "$$consumer" = summon ]; then chart="$(SUMMON_DIR)"; values="$$tmp_dir/summon.yaml"; fi; \
			output="$$tmp_dir/$$namespace-$$consumer"; \
			helm template "$(TEST_RELEASE)" "$$chart" --namespace "$$namespace" -f "$$values" | yq -s '.' > "$$output.json"; \
			jq -r '.[] | select(.kind == "ConfigMap" and .metadata.labels.grafana_alert == "1") | .data[] | "---\n" + .' \
				"$$output.json" | yq -s '.' > "$$output-alerts.json"; \
			jq '[.[] | select(.kind == "ConfigMap" and .metadata.labels.grafana_dashboard == "1") | .data[] | fromjson]' \
				"$$output.json" > "$$output-dashboards.json"; \
			jq -e --arg namespace "$$namespace" --slurpfile alerts "$$output-alerts.json" \
				--slurpfile dashboards "$$output-dashboards.json" -f "$$fixture/observability.jq" "$$output.json" >/dev/null; \
			jq '[.[] | .groups[]?.rules[]?.uid] | sort' "$$output-alerts.json" > "$$output-uids.json"; \
			echo "$(GREEN)PASS$(RESET) PostgreSQL contracts through $$consumer in $$namespace"; \
		done; \
		diff -u "$$tmp_dir/$$namespace-kaster-uids.json" "$$tmp_dir/$$namespace-summon-uids.json"; \
	done; \
	jq -e -s '([.[0][]] + [.[1][]]) as $$uids | ($$uids | length) == ($$uids | unique | length)' \
		"$$tmp_dir/tenant-blue-kaster-uids.json" "$$tmp_dir/tenant-red-kaster-uids.json" >/dev/null; \
	for consumer in kaster summon; do \
		alerts="$$tmp_dir/tenant-blue-$$consumer-alerts.json"; \
		jq -n --arg mode rules --slurpfile alerts "$$alerts" --slurpfile cases "$$tmp_dir/cases.json" \
			-f "$$fixture/prometheus.jq" | yq -y '.' > "$$tmp_dir/rules.yaml"; \
		jq -n --arg mode tests --slurpfile alerts "$$alerts" --slurpfile cases "$$tmp_dir/cases.json" \
			-f "$$fixture/prometheus.jq" | yq -y '.' > "$$tmp_dir/prometheus-test.yaml"; \
		"$$promtool" check rules "$$tmp_dir/rules.yaml"; \
		"$$promtool" test rules "$$tmp_dir/prometheus-test.yaml"; \
	done

test-glyph-contracts: test-postgresql-observability
	@command -v yq >/dev/null 2>&1 || { \
		echo "$(RED)$(BOLD)Error:$(RESET) yq is required for Glyph contract tests" >&2; \
		exit 1; \
	}; \
	tmp_dir=$$(mktemp -d); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	render_with_both_dispatchers() { \
		fixture="$$1"; chart_key="$$2"; label="$$3"; \
		$(HELM_TEST) ./$(KASTER_DIR) -f "$$fixture" > "$$tmp_dir/$$label-kaster.yaml"; \
		yq -y --arg chart "$$chart_key" \
			'.[$$chart] = (.glyphs[$$chart] | if type == "array" then to_entries | map({key: (.key | tostring), value: .value}) | from_entries else . end) | del(.glyphs) | .workload.enabled = false' \
			"$$fixture" > "$$tmp_dir/$$label-summon-values.yaml"; \
		$(HELM_TEST) ./$(SUMMON_DIR) \
			-f "$$tmp_dir/$$label-summon-values.yaml" > "$$tmp_dir/$$label-summon.yaml"; \
	}; \
	provider_fixture="$(GLYPHS_DIR)/cert-manager/examples/cluster-issuer-providers.yaml"; \
	legacy_fixture="$(GLYPHS_DIR)/certManager/examples/legacy-cluster-issuer.yaml"; \
	test -f "$$provider_fixture"; \
	test -f "$$legacy_fixture"; \
	render_with_both_dispatchers "$$provider_fixture" cert-manager cluster-issuer-providers; \
	for dispatcher in kaster summon; do \
		output="$$tmp_dir/cluster-issuer-providers-$$dispatcher.yaml"; \
		yq -s -e '([.[] | select(.kind == "ClusterIssuer")] | length == 3) and any(.[]; .kind == "ClusterIssuer" and .metadata.name == "letsencrypt-aws" and .spec.acme.solvers[0].dns01.route53.region == "eu-west-1" and .spec.acme.solvers[0].dns01.route53.hostedZoneID == "Z1234567890ABC" and .spec.acme.solvers[0].dns01.route53.role == "arn:aws:iam::123456789012:role/cert-manager" and .spec.acme.solvers[0].dns01.route53.accessKeyID == "AKIAEXAMPLE" and .spec.acme.solvers[0].dns01.route53.secretAccessKeySecretRef.name == "route53-credentials") and any(.[]; .kind == "ClusterIssuer" and .metadata.name == "letsencrypt-gcp" and .spec.acme.solvers[0].dns01.cloudDNS.project == "example-project" and .spec.acme.solvers[0].dns01.cloudDNS.serviceAccountSecretRef.name == "clouddns-credentials") and any(.[]; .kind == "ClusterIssuer" and .metadata.name == "letsencrypt-cloudflare" and .spec.acme.solvers[0].dns01.cloudflare.apiTokenSecretRef.name == "cloudflare-api-token")' "$$output" >/dev/null; \
	done; \
	echo "$(GREEN)PASS$(RESET) provider ClusterIssuers render through Kaster and Summon"; \
	render_with_both_dispatchers "$$legacy_fixture" certManager legacy-cert-manager; \
	for dispatcher in kaster summon; do \
		output="$$tmp_dir/legacy-cert-manager-$$dispatcher.yaml"; \
		yq -s -e '[.[] | select(.kind == "ClusterIssuer" and .metadata.name == "letsencrypt-legacy" and .spec.acme.solvers[0].dns01.route53.region == "us-east-1")] | length == 1' "$$output" >/dev/null; \
	done; \
	echo "$(GREEN)PASS$(RESET) deprecated certManager dispatch works through Kaster and Summon"; \
	workflow_fixture="tests/glyph-contracts/workflow-trigger-generate-name.yaml"; \
	workflow_output="$$tmp_dir/workflow-trigger-generate-name.yaml"; \
	$(HELM_TEST) ./$(KASTER_DIR) -f "$$workflow_fixture" > "$$workflow_output"; \
	yq -s -e 'any(.[]; .kind == "Sensor" and .spec.triggers[0].template.argoWorkflow.source.resource.metadata.generateName == "component-reading-" and .spec.triggers[0].template.argoWorkflow.parameters[0].src.dependencyName == "component-trigger" and .spec.triggers[0].template.argoWorkflow.parameters[0].src.dataTemplate == "runik-component-pr-gate-{{ .Input.body.repository.name }}-" and .spec.triggers[0].template.argoWorkflow.parameters[0].dest == "metadata.generateName" and .spec.triggers[0].template.argoWorkflow.parameters[1].dest == "spec.arguments.parameters.0.value")' "$$workflow_output" >/dev/null; \
	yq -y '.lexicon."component-trigger".generateName.from = "body.repository.name"' \
		"$$workflow_fixture" > "$$tmp_dir/workflow-trigger-invalid.yaml"; \
	if $(HELM_TEST) ./$(KASTER_DIR) -f "$$tmp_dir/workflow-trigger-invalid.yaml" \
		> "$$tmp_dir/workflow-trigger-invalid.out" 2>&1; then \
		echo "$(RED)FAIL$(RESET) ambiguous workflow generateName was accepted" >&2; \
		exit 1; \
	fi; \
	rg -Fq 'generateName requires exactly one of from, dataTemplate or value' \
		"$$tmp_dir/workflow-trigger-invalid.out"; \
	echo "$(GREEN)PASS$(RESET) workflow-trigger derives safe dynamic Workflow names"; \
	render_with_both_dispatchers "$(GLYPHS_DIR)/external-secrets/examples/basic-push-secrets.yaml" external-secrets secret-roots; \
	for dispatcher in kaster summon; do \
		output="$$tmp_dir/secret-roots-$$dispatcher.yaml"; \
		for provider in vault aws gcp; do \
			key="acme/prod/default/$(TEST_NAMESPACE)/publics/rooted-$$provider-credentials"; \
			if [ "$$provider" = vault ]; then key="kv/data/$$key"; fi; \
			yq -s -e --arg name "rooted-$$provider-credentials" --arg key "$$key" \
				'any(.[]; .kind == "ExternalSecret" and .metadata.name == $$name and .spec.dataFrom[0].extract.key == $$key) and any(.[]; .kind == "PushSecret" and .metadata.name == $$name and .spec.data[0].match.remoteRef.remoteKey == $$key)' "$$output" >/dev/null; \
		done; \
		yq -s -e 'any(.[]; .kind == "ExternalSecret" and .metadata.name == "rooted-explicit-key" and .spec.data[0].remoteRef.key == "shared/token") and any(.[]; .kind == "ExternalSecret" and .metadata.name == "rooted-explicit-extract" and .spec.dataFrom[0].extract.key == "shared/token") and any(.[]; .kind == "PushSecret" and .metadata.name == "rooted-explicit-push" and .spec.data[0].match.remoteRef.remoteKey == "shared/token") and any(.[]; .kind == "ExternalSecret" and .metadata.name == "rooted-chapter-data" and .spec.data[0].remoteRef.key == "acme/prod/default/publics/rooted-chapter-data") and any(.[]; .kind == "PushSecret" and .metadata.name == "rooted-chapter-data" and .spec.data[0].match.remoteRef.remoteKey == "acme/prod/default/publics/rooted-chapter-data")' "$$output" >/dev/null; \
	done; \
	echo "$(GREEN)PASS$(RESET) common roots agree across providers and both dispatchers; explicit keys remain authoritative"; \
	for invalid in '""' 'null' 'false' '123' '[]' '{}' '"/root"' '"root/"' '"root//child"' '"root/../child"' '"root/*"' '"root/+"' '"root with spaces"'; do \
		yq -y --argjson invalid "$$invalid" '.glyphs.common[0].store.pathRoot = $$invalid' \
			"$(GLYPHS_DIR)/common/examples/secretpath-basic.yaml" > "$$tmp_dir/invalid-root.yaml"; \
		if $(HELM_TEST) ./$(KASTER_DIR) -f "$$tmp_dir/invalid-root.yaml" > "$$tmp_dir/invalid-root.log" 2>&1; then \
			echo "FAIL: invalid pathRoot $$invalid was accepted" >&2; exit 1; \
		fi; \
		rg -Fq 'secret-store.pathRoot' "$$tmp_dir/invalid-root.log"; \
	done; \
	echo "$(GREEN)PASS$(RESET) invalid secret roots fail during rendering"; \
	$(HELM_TEST) ./$(KASTER_DIR) -f "$(GLYPHS_DIR)/postgresql/examples/db-multiple-vault-engines.yaml" > "$$tmp_dir/database-roots.yaml"; \
	yq -s -e 'any(.[]; .kind == "DatabaseSecretEngineConfig" and .spec.path == "analytics-db/tenant/analytics/apps/multi-engine") and any(.[]; .kind == "VaultSecret" and .spec.vaultSecretDefinitions[0].path == "analytics-db/tenant/analytics/apps/multi-engine/creds/reports") and any(.[]; .kind == "Policy" and (.spec.policy | contains("sys/mounts/analytics-db/tenant/analytics/apps/multi-engine"))) and any(.[]; .kind == "DatabaseSecretEngineConfig" and .spec.path == "db/test-book/apps/multi-engine")' "$$tmp_dir/database-roots.yaml" >/dev/null; \
	echo "$(GREEN)PASS$(RESET) database mounts, readers and policies share the selected store root"; \
	$(HELM_TEST) ./$(KASTER_DIR) -f "$(GLYPHS_DIR)/vault/examples/path-variants.yaml" > "$$tmp_dir/vault-roots.yaml"; \
	yq -s -e 'any(.[]; .kind == "Policy" and .metadata.name == "developer" and (.spec.policy | contains("kv/data/acme/prod/publics/*")))' "$$tmp_dir/vault-roots.yaml" >/dev/null; \
	yq -y 'del(.lexicon[].pathRoot)' "$(GLYPHS_DIR)/vault/examples/path-variants.yaml" > "$$tmp_dir/vault-legacy.yaml"; \
	$(HELM_TEST) ./$(KASTER_DIR) -f "$$tmp_dir/vault-legacy.yaml" > "$$tmp_dir/vault-legacy-output.yaml"; \
	yq -s -e 'any(.[]; .kind == "Policy" and .metadata.name == "developer" and (.spec.policy | contains("secret/data/default/publics/*")))' "$$tmp_dir/vault-legacy-output.yaml" >/dev/null; \
	echo "$(GREEN)PASS$(RESET) OIDC policies use the configured root/mount and retain legacy paths without it"; \
	yq -y '(.lexicon[] | select(.type == "secret-store")).pathRoot = "acme/prod"' \
		"$(GLYPHS_DIR)/s3/examples/bucket-basic.yaml" > "$$tmp_dir/s3-root.yaml"; \
	$(HELM_TEST) ./$(KASTER_DIR) -f "$$tmp_dir/s3-root.yaml" > "$$tmp_dir/s3-root-output.yaml"; \
	yq -s -e '[.[] | select(.kind == "VaultSecret") | .spec.vaultSecretDefinitions[].path] as $$reads | [.[] | select(.kind == "RandomSecret") | (.spec.path + .metadata.name)] as $$writes | ($$reads | length > 0) and ($$writes | length > 0) and all($$reads[]; startswith("kv/data/acme/prod/staging/")) and all($$writes[]; . as $$path | $$reads | index($$path) != null)' "$$tmp_dir/s3-root-output.yaml" >/dev/null; \
	yq -y '(.lexicon[] | select(.type == "secret-store")).pathRoot = "acme/prod"' \
		"$(GLYPHS_DIR)/s3/examples/versity-infrastructure.yaml" > "$$tmp_dir/s3-aggregator-root.yaml"; \
	$(HELM_TEST) ./$(KASTER_DIR) -f "$$tmp_dir/s3-aggregator-root.yaml" > "$$tmp_dir/s3-aggregator-root-output.yaml"; \
	yq -s -e 'any(.[]; .kind == "Policy" and (.spec.policy | contains("secret/data/acme/prod/+/publics/s3-identities-gateway-*")) and (.spec.policy | contains("secret/metadata/acme/prod/+/publics/s3-identities-gateway-*")))' "$$tmp_dir/s3-aggregator-root-output.yaml" >/dev/null; \
	echo "$(GREEN)PASS$(RESET) S3 secret readers, writers and aggregator permissions use the common root"

test-autoscaling:
	@for tool in helm yq jq; do command -v "$$tool" >/dev/null; done; \
	temporary=$$(mktemp -d); \
	trap 'rm -rf "$$temporary"' EXIT; \
	for chart in "$(SUMMON_DIR)" "$(MICROSPELL_DIR)"; do \
		for workload in deployment statefulset; do \
			kind=Deployment; [ "$$workload" != statefulset ] || kind=StatefulSet; \
			render() { \
				echo "Testing $$chart/$$workload: enabled=$$1 mode=$$2 replicas=$$3"; \
				jq -n --arg workload "$$workload" --argjson enabled "$$1" \
					--arg mode "$$2" --arg replicas "$$3" \
					'{name: "scaling-test", image: {repository: "nginx", tag: "stable"},  service: {enabled: false}, serviceAccount: {enabled: false},  workload: {enabled: true, type: $$workload},  autoscaling: {enabled: $$enabled, minReplicas: 2, maxReplicas: 9,  targetCPUUtilizationPercentage: 65, targetMemoryUtilizationPercentage: 75,  labels: {scaling: "test"}, annotations: {owner: "test"}}}  | if $$mode == "omitted" then . elif $$mode == "unset" then .autoscaling.mode = null else .autoscaling.mode = $$mode end  | if $$replicas == "omitted" then . else .workload.replicas = ($$replicas | fromjson) end' \
					> "$$temporary/values.json"; \
				$(HELM_TEST) "$$chart" -f "$$temporary/values.json" > "$$temporary/render.yaml" 2> "$$temporary/error"; \
			}; \
			for mode in omitted unset hpa external invalid fixed ""; do \
				for replicas in omitted null 4 0; do \
					render false "$$mode" "$$replicas"; \
					expected=$$replicas; \
					if [ "$$replicas" = omitted ]; then \
						expected=1; [ "$$chart" != "$(MICROSPELL_DIR)" ] || expected=2; \
					elif [ "$$replicas" = null ]; then expected=1; fi; \
					yq -s -e --arg kind "$$kind" --argjson replicas "$$expected" \
						'([.[] | select(.kind == $$kind)] | length == 1) and  all(.[]; if .kind == $$kind then .spec.replicas == $$replicas else true end) and  all(.[]; .kind != "HorizontalPodAutoscaler")' "$$temporary/render.yaml" >/dev/null; \
				done; \
			done; \
			for mode in omitted unset hpa external; do \
				for replicas in null 4 0; do \
					render true "$$mode" "$$replicas"; \
					yq -s -e --arg kind "$$kind" \
						'([.[] | select(.kind == $$kind)] | length == 1) and  all(.[]; if .kind == $$kind then (.spec | has("replicas") | not) else true end)' \
						"$$temporary/render.yaml" >/dev/null; \
					if [ "$$mode" = external ]; then \
						yq -s -e --arg kind "$$kind" 'all(.[] | select(. != null); .kind == $$kind)' \
							"$$temporary/render.yaml" >/dev/null; \
					else \
						minimum=2; [ "$$replicas" != 4 ] || minimum=4; \
						yq -s -e --argjson minimum "$$minimum" \
							'([.[] | select(.kind == "HorizontalPodAutoscaler")] | length == 1) and  any(.[]; .kind == "HorizontalPodAutoscaler" and .apiVersion == "autoscaling/v2" and  .metadata.labels.scaling == "test" and .metadata.annotations.owner == "test" and  .spec == {scaleTargetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "scaling-test"},  minReplicas: $$minimum, maxReplicas: 9, metrics: [  {type: "Resource", resource: {name: "cpu", target: {type: "Utilization", averageUtilization: 65}}},  {type: "Resource", resource: {name: "memory", target: {type: "Utilization", averageUtilization: 75}}}]})' \
							"$$temporary/render.yaml" >/dev/null; \
					fi; \
				done; \
			done; \
			for mode in invalid fixed ""; do \
				if render true "$$mode" omitted; then \
					echo "FAIL: enabled autoscaling accepted mode $$mode" >&2; exit 1; \
				fi; \
				grep -Fq "unsupported autoscaling.mode \"$$mode\": expected hpa or external" "$$temporary/error"; \
			done; \
		done; \
	done; \
	echo "PASS: Summon and Microspell autoscaling contracts"

test-librarian:
	@for tool in helm yq jq diff rg; do command -v "$$tool" >/dev/null; done; \
	temporary=$$(mktemp -d); \
	trap 'rm -rf "$$temporary"' EXIT; \
	chart="$$temporary/librarian"; \
	book="$$temporary/bookrack/kustomize-contract"; \
	mkdir -p "$$chart" "$$book/apps"; \
	cp -a "$(LIBRARIAN_DIR)/Chart.yaml" "$(LIBRARIAN_DIR)/values.yaml" "$(LIBRARIAN_DIR)/templates" "$(LIBRARIAN_DIR)/charts" "$(LIBRARIAN_DIR)/bookrack" "$$chart/"; \
	cp tests/librarian/kustomize/index.yaml "$$book/index.yaml"; \
	yq . tests/librarian/kustomize/operator.yaml > "$$temporary/fixture.json"; \
	spell="$$book/apps/operator.yaml"; \
	actual="$$temporary/application.json"; \
	render() { \
		helm template kustomize-contract "$$chart" > "$$temporary/render.yaml"; \
		yq -s -S '.[] | select(.kind == "Application")' "$$temporary/render.yaml" > "$$actual"; \
	}; \
	cp "$$temporary/fixture.json" "$$spell"; \
	render; \
	jq -e --slurpfile fixture "$$temporary/fixture.json" -f tests/librarian/kustomize/sources.jq "$$actual" >/dev/null; \
	echo "PASS: primary/rune options are preserved and isolated from other sources"; \
	jq '.kustomize = {} | .runes[0].kustomize = {}' "$$temporary/fixture.json" > "$$spell"; \
	render; \
	jq -e ' .spec.sources[0].kustomize == {} and .spec.sources[2].kustomize == {} and (.spec.sources[0] | has("helm") | not) and (.spec.sources[2] | has("helm") | not) ' "$$actual" >/dev/null; \
	echo "PASS: empty maps explicitly select Kustomize"; \
	for mode in omitted false true; do \
		jq 'del(.kustomize, .runes[0].kustomize)' "$$temporary/fixture.json" > "$$temporary/existing.json"; \
		if [ "$$mode" = omitted ]; then \
			cp "$$temporary/existing.json" "$$spell"; \
		else \
			jq --argjson flag "$$mode" '.appParams.noHelm = $$flag | .runes[0].appParams.noHelm = $$flag' "$$temporary/existing.json" > "$$spell"; \
		fi; \
		render; \
		if [ "$$mode" = true ]; then baseline=noHelm; else baseline=default; fi; \
		jq -S --arg baseline "$$baseline" '.[$$baseline]' tests/librarian/kustomize/existing-applications.json > "$$temporary/expected.json"; \
		diff -u "$$temporary/expected.json" "$$actual"; \
	done; \
	echo "PASS: complete existing Applications are unchanged for omitted/false/true noHelm"; \
	for scope in spell rune; do \
		if [ "$$scope" = spell ]; then source_path='[]'; else source_path='["runes",0]'; fi; \
		for invalid in chart missing-path null list string; do \
			case "$$invalid" in \
				chart) filter='setpath($$path + ["chart"]; "operator")'; error="requires a path source without chart" ;; \
				missing-path) filter='delpaths([$$path + ["path"]])'; error="requires a path source without chart" ;; \
				null) filter='setpath($$path + ["kustomize"]; null)'; error="must be a map" ;; \
				list) filter='setpath($$path + ["kustomize"]; [])'; error="must be a map" ;; \
				string) filter='setpath($$path + ["kustomize"]; "invalid")'; error="must be a map" ;; \
			esac; \
			jq --argjson path "$$source_path" "$$filter" "$$temporary/fixture.json" > "$$spell"; \
			if helm template kustomize-contract "$$chart" > "$$temporary/error.log" 2>&1; then \
				echo "FAIL: $$scope accepted $$invalid Kustomize source" >&2; \
				exit 1; \
			fi; \
			rg -Fq "$$error" "$$temporary/error.log"; \
			rg -Fq "apps/operator.yaml" "$$temporary/error.log"; \
			if [ "$$scope" = rune ]; then rg -Fq "rune kustomize" "$$temporary/error.log"; fi; \
		done; \
	done; \
	echo "PASS: invalid source combinations and types fail during rendering"; \
	awk -v directory="$$temporary" ' $$0 == sprintf("%c%c%cyaml", 96, 96, 96) { block++; inside=1; next } $$0 == sprintf("%c%c%c", 96, 96, 96) { inside=0; next } inside { print > (directory "/example-" block ".yaml") } ' docs/usage/kustomize.md; \
	checked=0; \
	for example in "$$temporary"/example-*.yaml; do \
		if ! yq -e 'has("name")' "$$example" >/dev/null; then continue; fi; \
		yq . "$$example" > "$$spell"; \
		render; \
		jq -e --slurpfile spell "$$spell" ' $$spell[0] as $$definition | if $$definition | has("kustomize") then .spec.sources[0].kustomize == $$definition.kustomize and (.spec.sources[0] | has("helm") | not) else .spec.sources[-1].kustomize == $$definition.runes[0].kustomize and (.spec.sources[-1] | has("helm") | not) end ' "$$actual" >/dev/null; \
		checked=$$((checked + 1)); \
	done; \
	test "$$checked" -eq 2; \
	echo "PASS: documentation examples render with their declared source options"; \
	book="$$temporary/bookrack/namespace-contract"; \
	mkdir -p "$$book/apps"; \
	yq . tests/librarian/namespaces.yaml > "$$temporary/namespaces.json"; \
	jq '.index' "$$temporary/namespaces.json" > "$$temporary/namespace-index.json"; \
	write_namespace_spells() { \
		while IFS= read -r definition; do \
			name=$$(printf '%s' "$$definition" | jq -r .name); \
			printf '%s\n' "$$definition" > "$$book/apps/$$name.yaml"; \
		done; \
	}; \
	jq -c '.cases[]' "$$temporary/namespaces.json" | while IFS= read -r case_data; do \
		printf '%s\n' "$$case_data" > "$$temporary/namespace-case.json"; \
		label=$$(jq -r .name "$$temporary/namespace-case.json"); \
		echo "Testing namespace inheritance: $$label"; \
		jq -s '.[0] * .[1].book' "$$temporary/namespace-index.json" "$$temporary/namespace-case.json" > "$$book/index.yaml"; \
		if jq -e '.chapter != null' "$$temporary/namespace-case.json" >/dev/null; then \
			jq '.chapter' "$$temporary/namespace-case.json" > "$$book/apps/index.yaml"; \
		else \
			rm -f "$$book/apps/index.yaml"; \
		fi; \
		jq -c --slurpfile case_data "$$temporary/namespace-case.json" \
			'.sources[] * $$case_data[0].spell' "$$temporary/namespaces.json" | write_namespace_spells; \
		helm template namespace-contract "$$chart" > "$$temporary/render.yaml"; \
		yq -s -S '[.[] | select(.kind == "Application") | {name: .metadata.name, argocdNamespace: .metadata.namespace, server: .spec.destination.server, namespace: .spec.destination.namespace}] | sort_by(.name)' \
			"$$temporary/render.yaml" > "$$actual"; \
		jq -S --slurpfile case_data "$$temporary/namespace-case.json" \
			'[.sources[] | {name: ("app-" + .name + "-test"), argocdNamespace: "argocd-control", server: "https://kubernetes.default.svc", namespace: ($$case_data[0].expected // .name)}] | sort_by(.name)' \
			"$$temporary/namespaces.json" > "$$temporary/expected.json"; \
		diff -u "$$temporary/expected.json" "$$actual"; \
	done; \
	echo "PASS: namespace precedence for Summon, chart, Helm path, and Kustomize sources"; \
	jq '.index | .namespace = "book-ns" | .chapters = ["apps", "inherited", "other"]' \
		"$$temporary/namespaces.json" > "$$book/index.yaml"; \
	jq -n '{namespace: "chapter-ns"}' > "$$book/apps/index.yaml"; \
	jq -c '.sources[] + {namespace: "spell-ns"}' "$$temporary/namespaces.json" | write_namespace_spells; \
	jq -n '{name: "sibling"}' > "$$book/apps/sibling.yaml"; \
	for chapter in inherited other; do \
		mkdir -p "$$book/$$chapter"; \
		jq -n --arg name "$$chapter" '{name: $$name}' > "$$book/$$chapter/service.yaml"; \
	done; \
	jq -n '{namespace: "other-ns"}' > "$$book/other/index.yaml"; \
	helm template namespace-contract "$$chart" > "$$temporary/render.yaml"; \
	yq -s -S '[.[] | select(.kind == "Application") | {key: .metadata.name, value: .spec.destination.namespace}] | from_entries' \
		"$$temporary/render.yaml" > "$$actual"; \
	jq -n -S '{"app-chart-test": "spell-ns", "app-kustomize-test": "spell-ns", "app-path-test": "spell-ns", "app-summon-test": "spell-ns", "app-sibling-test": "chapter-ns", "app-inherited-test": "book-ns", "app-other-test": "other-ns"}' \
		> "$$temporary/expected.json"; \
	diff -u "$$temporary/expected.json" "$$actual"; \
	echo "PASS: namespace overrides do not leak across spells or chapters";

ci: verify
	@$(MAKE) --no-print-directory test-component-candidate
	@$(MAKE) --no-print-directory test-glyph-name-checker
	@$(MAKE) --no-print-directory check-glyph-names
	@$(MAKE) --no-print-directory test-glyph-contracts
	@$(MAKE) --no-print-directory test-autoscaling
	@$(MAKE) --no-print-directory test-librarian
	@$(MAKE) --no-print-directory smoke
	@$(MAKE) --no-print-directory test all
	@$(MAKE) --no-print-directory test integration
	@$(MAKE) --no-print-directory test covenant

# The caller checks out the candidate component at its canonical Runik path.
# For Glyphs it must also place the same commit in every consumer mirror.
# A consumer dependency update prepares the same future Glyphs set locally;
# it never changes recorded gitlinks or merges any consumer repositories.
# Snapshot regeneration is disposable in this mode: component repositories do
# not own Runik's aggregate snapshots, which component-sync updates after merge.
test-component-candidate:
	@python3 tests/component-candidate/test_candidate.py

prepare-component-candidate:
	@component="$(COMPONENT)"; \
	case "$$component" in \
		glyphs|librarian) exit 0 ;; \
		covenant) component_path="$(COVENANT_DIR)" ;; \
		summon) component_path="$(SUMMON_DIR)" ;; \
		kaster) component_path="$(KASTER_DIR)" ;; \
		tarot) component_path="$(TAROT_DIR)" ;; \
		microspell) component_path="$(MICROSPELL_DIR)" ;; \
		*) echo "Unsupported Runik component: $$component" >&2; exit 1 ;; \
	esac; \
	candidate_glyphs=$$(git -C "$$component_path" ls-tree HEAD charts | awk '$$1 == "160000" {print $$3}'); \
	test -n "$$candidate_glyphs" || { echo "$$component must pin its Glyphs dependency" >&2; exit 1; }; \
	test "$$(git -C "$$component_path/charts" rev-parse HEAD)" = "$$candidate_glyphs" || { \
		echo "$$component Glyphs checkout does not match its committed dependency" >&2; exit 1; \
	}; \
	canonical_glyphs=$$(git -C "$(GLYPHS_DIR)" rev-parse HEAD); \
	if [ "$$candidate_glyphs" = "$$canonical_glyphs" ]; then exit 0; fi; \
	for mirror in $(GLYPH_MIRRORS); do \
		if [ "$$mirror" = "$$component_path/charts" ]; then continue; fi; \
		test "$$(git -C "$$mirror" rev-parse HEAD)" = "$$canonical_glyphs" || { \
			echo "Unrelated Glyphs mismatch in $$mirror; refusing candidate preparation" >&2; exit 1; \
		}; \
	done; \
	git -C "$(GLYPHS_DIR)" fetch --quiet --no-tags origin \
		+refs/heads/upstream:refs/remotes/origin/upstream; \
	git -C "$(GLYPHS_DIR)" merge-base --is-ancestor "$$candidate_glyphs" refs/remotes/origin/upstream || { \
		echo "Candidate Glyphs dependency must already be merged into origin/upstream" >&2; exit 1; \
	}; \
	git -C "$(GLYPHS_DIR)" merge-base --is-ancestor "$$canonical_glyphs" "$$candidate_glyphs" || { \
		echo "Candidate Glyphs dependency must advance Runik's current dependency" >&2; exit 1; \
	}; \
	for glyph_path in "$(GLYPHS_DIR)" $(GLYPH_MIRRORS); do \
		git -C "$$glyph_path" diff --quiet HEAD -- . || { \
			echo "Dirty Glyphs checkout in $$glyph_path; refusing candidate preparation" >&2; exit 1; \
		}; \
	done; \
	for glyph_path in "$(GLYPHS_DIR)" $(GLYPH_MIRRORS); do \
		git -C "$$glyph_path" fetch --quiet --no-tags "$(abspath $(GLYPHS_DIR))" "$$candidate_glyphs"; \
		git -C "$$glyph_path" checkout --quiet --detach "$$candidate_glyphs"; \
	done; \
	echo "Prepared future Runik Glyphs set at $$candidate_glyphs for $$component"

verify-component-candidate:
	@component="$(COMPONENT)"; \
	case "$$component" in \
		librarian) component_path="$(LIBRARIAN_DIR)" ;; \
		covenant) component_path="$(COVENANT_DIR)" ;; \
		summon) component_path="$(SUMMON_DIR)" ;; \
		kaster) component_path="$(KASTER_DIR)" ;; \
		tarot) component_path="$(TAROT_DIR)" ;; \
		microspell) component_path="$(MICROSPELL_DIR)" ;; \
		glyphs) component_path="$(GLYPHS_DIR)" ;; \
		*) \
			echo "$(RED)$(BOLD)Error:$(RESET) COMPONENT must be one of: glyphs librarian covenant summon kaster tarot microspell" >&2; \
			exit 1; \
			;; \
	esac; \
	test -d "$$component_path" || { \
		echo "$(RED)$(BOLD)Error:$(RESET) candidate path is missing: $$component_path" >&2; \
		exit 1; \
	}; \
	case "$$component" in \
		librarian|covenant) \
			test "$$(git -C "$$component_path" ls-files -s -- bookrack | awk 'NR == 1 {print $$1}')" = 120000; \
			test "$$(git -C "$$component_path" show :bookrack)" = ../bookrack \
				|| { echo "$$component must preserve bookrack -> ../bookrack" >&2; exit 1; }; \
			;; \
	esac; \
	canonical_glyphs=$$(git -C "$(GLYPHS_DIR)" rev-parse HEAD); \
	for mirror in $(GLYPH_MIRRORS); do \
		mirror_glyphs=$$(git -C "$$mirror" rev-parse HEAD); \
		if [ "$$mirror_glyphs" != "$$canonical_glyphs" ]; then \
			echo "$(RED)FAIL$(RESET) $$mirror is at $$mirror_glyphs, expected $$canonical_glyphs" >&2; \
			exit 1; \
		fi; \
	done; \
	echo "$(GREEN)PASS$(RESET) testing Runik with candidate $$component at $$(git -C "$$component_path" rev-parse --short HEAD)"

ci-component-candidate: prepare-component-candidate
	@$(MAKE) --no-print-directory verify-component-candidate COMPONENT="$(COMPONENT)"
	@$(MAKE) --no-print-directory test-component-candidate
	@$(MAKE) --no-print-directory test-glyph-name-checker
	@$(MAKE) --no-print-directory check-glyph-names
	@$(MAKE) --no-print-directory test-glyph-contracts
	@$(MAKE) --no-print-directory test-autoscaling
	@$(MAKE) --no-print-directory test-librarian
	@$(MAKE) --no-print-directory snapshot all
	@$(MAKE) --no-print-directory test all
	@$(MAKE) --no-print-directory smoke
	@$(MAKE) --no-print-directory test integration
	@$(MAKE) --no-print-directory test covenant

ci-glyphs-candidate:
	@$(MAKE) --no-print-directory ci-component-candidate COMPONENT=glyphs

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
