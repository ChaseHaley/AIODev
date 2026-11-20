package links_test

import "aio:links"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// Builds `files` under a fresh temporary folder; names use '/' and folders are made as needed.
@(private = "file")
tree_make :: proc(t: ^testing.T, files: []string) -> (root: string, ok: bool) {
	directory, err := os.make_directory_temp("", "aio-vault-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return "", false}
	for file in files {
		path, _ := strings.replace_all(strings.concatenate({directory, "/", file}, context.temp_allocator), "/", `\`,
			context.temp_allocator)
		if strings.has_suffix(path, `\`) {
			if !testing.expect_value(t, os.make_directory_all(path), nil) {return directory, false}
			continue
		}
		folder := path[:strings.last_index_byte(path, '\\')]
		if !testing.expect_value(t, os.make_directory_all(folder), nil) {return directory, false}
		if !testing.expect_value(t, os.write_entire_file(path, "# Note\n"), nil) {return directory, false}
	}
	return directory, true
}

@(private = "file")
tree_destroy :: proc(t: ^testing.T, root: string) {
	testing.expect_value(t, os.remove_all(root), nil)
	delete(root)
}

// The path a wikilink resolves to, relative to root with '/', or "" when it resolves to nothing.
@(private = "file")
resolved :: proc(root, document, name: string) -> string {
	buffer: [links.TARGET_BYTES]u8
	from := strings.concatenate({root, `\`, document}, context.temp_allocator)
	from, _ = strings.replace_all(from, "/", `\`, context.temp_allocator)
	path, ok := links.resolve_wiki(name, from, buffer[:])
	if !ok {return ""}
	if !strings.has_prefix(path, root) {return strings.clone(path, context.temp_allocator)}
	relative, _ := strings.replace_all(path[len(root) + 1:], `\`, "/", context.temp_allocator)
	return relative
}

@(test)
wikilinks_resolve_within_the_vault_nearest_the_document :: proc(t: ^testing.T) {
	root, ok := tree_make(t, {
		"vault/.obsidian/",
		"vault/.obsidian/Plan.md",
		"vault/.trash/Ideas.md",
		"vault/Home.md",
		"vault/Plan.md",
		"vault/notes/doc.md",
		"vault/notes/plan.md",
		"vault/notes/deep/Shared.md",
		"vault/other/Shared.md",
		"vault/Area/Shared.md",
		"vault/Area/Topic.md",
		"vault/notes/Topic.md",
		"vault/assets/chart.png",
		"vault/v1.2 notes.md",
		"vault/Readme",
	})
	defer tree_destroy(t, root)
	if !ok {return}
	doc := "vault/notes/doc.md"

	// The name ignores case and the copy beside the document wins over the root's.
	testing.expect_value(t, resolved(root, doc, "PLAN"), "vault/notes/plan.md")
	// A note anywhere in the vault, found from below the document's folder.
	testing.expect_value(t, resolved(root, doc, "Home"), "vault/Home.md")
	// One step down beats two steps across; equal steps fall to the shorter, then earlier, path.
	testing.expect_value(t, resolved(root, doc, "Shared"), "vault/notes/deep/Shared.md")
	testing.expect_value(t, resolved(root, "vault/Home.md", "Shared"), "vault/Area/Shared.md")
	// An explicit .md, another extension as written, and a dotted note name.
	testing.expect_value(t, resolved(root, doc, "Home.md"), "vault/Home.md")
	testing.expect_value(t, resolved(root, doc, "chart.png"), "vault/assets/chart.png")
	testing.expect_value(t, resolved(root, doc, "v1.2 notes"), "vault/v1.2 notes.md")
	// No extension means a note, not a file of that bare name.
	testing.expect_value(t, resolved(root, doc, "Readme"), "")
	// A folder in the name is vault-relative first, then a path ending anywhere in the vault.
	testing.expect_value(t, resolved(root, doc, "Area/Topic"), "vault/Area/Topic.md")
	testing.expect_value(t, resolved(root, "vault/Home.md", "notes/Topic"), "vault/notes/Topic.md")
	testing.expect_value(t, resolved(root, doc, "deep/Shared"), "vault/notes/deep/Shared.md")
	// Folders starting with '.' are never searched.
	testing.expect_value(t, resolved(root, doc, "Ideas"), "")
	// An empty name is the document itself.
	testing.expect_value(t, resolved(root, doc, ""), "vault/notes/doc.md")
	testing.expect_value(t, resolved(root, doc, "Missing"), "")
	testing.expect_value(t, resolved(root, doc, "a:b"), "")
}

@(test)
without_a_vault_marker_the_document_folder_is_the_vault :: proc(t: ^testing.T) {
	root, ok := tree_make(t, {
		"Above.md",
		"folder/doc.md",
		"folder/sub/Below.md",
		"folder/Beside.md",
	})
	defer tree_destroy(t, root)
	if !ok {return}
	doc := "folder/doc.md"
	testing.expect_value(t, resolved(root, doc, "below"), "folder/sub/Below.md")
	testing.expect_value(t, resolved(root, doc, "Beside"), "folder/Beside.md")
	// The file above the document's folder is outside the vault, as a path ending or a name.
	testing.expect_value(t, resolved(root, doc, "Above"), "")
	// A folder name still resolves relative to the document when the vault root does not have it.
	testing.expect_value(t, resolved(root, doc, "sub/Below"), "folder/sub/Below.md")
}

@(test)
markdown_hrefs_decode_escapes_once :: proc(t: ^testing.T) {
	cases := [?]struct {href, path: string} {
		{"My%20Note.md", `C:\vault\My Note.md`},
		{"100%.md", `C:\vault\100%.md`},
		{"a%2541.md", `C:\vault\a%41.md`},
		{"b%2.md", `C:\vault\b%2.md`},
		{"bad%00.md", ""},
		{"file:///C:/My%20Files/a.md", `C:/My Files/a.md`},
	}
	for c in cases {
		buffer: [links.TARGET_BYTES]u8
		path, ok := links.resolve_href(c.href, `C:\vault`, {}, buffer[:])
		testing.expectf(t, ok == (c.path != ""), "%s resolved %v", c.href, ok)
		testing.expect_value(t, path, c.path)
	}
}

@(test)
obsidian_urls_resolve_only_notes_in_the_named_vault :: proc(t: ^testing.T) {
	root, ok := tree_make(t, {
		"Main Vault/notes/Plan + v1.2.md",
		"Main Vault/notes/100%20.md",
		"Outside.md",
		"obsidian/",
	})
	defer if root != "" {tree_destroy(t, root)}
	if !ok {return}
	vault := strings.concatenate({root, `\Main Vault`}, context.temp_allocator)
	encoded, err := json.marshal(vault, {}, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	registry := strings.concatenate({`{"vaults":{"abcd1234":{"path":`, string(encoded), `,"open":true}}}`},
		context.temp_allocator)
	registry_path := strings.concatenate({root, `\obsidian\obsidian.json`}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(registry_path, registry), nil) {return}

	cases := [?]struct {query, relative: string} {
		{"vault=Main%20Vault&file=notes%2FPlan%20%2B%20v1.2", `notes\Plan + v1.2.md`},
		{"file=notes/Plan+%2B+v1.2.md&vault=abcd1234", `notes\Plan + v1.2.md`},
		{"vault=Main%20Vault&file=notes/100%2520", `notes\100%20.md`},
		{"vault=Unknown&file=notes/100%2520", ""},
		{"vault=abcd1234&file=notes/none", ""},
		{"vault=abcd1234&file=%2e%2e%2FOutside", ""},
		{"vault=abcd1234&file=notes%5c..%5c..%5cOutside", ""},
		{"vault=abcd1234&file=%2FOutside", ""},
		{"vault=abcd1234&file=C%3A%2FOutside", ""},
		{"vault=abcd1234&file=notes/100%2", ""},
		{"vault=abcd1234&file=notes/100%2520&file=Outside", ""},
	}
	for c in cases {
		uri := strings.concatenate({"obsidian://open?", c.query}, context.temp_allocator)
		path, found := links.resolve_obsidian(uri, root)
		testing.expectf(t, found == (c.relative != ""), "%s resolved to %q", uri, path)
		if found && c.relative != "" {
			want := strings.concatenate({vault, `\`, c.relative}, context.temp_allocator)
			testing.expectf(t, strings.equal_fold(path, want), "resolved %q, want %q", path, want)
		}
	}
}
