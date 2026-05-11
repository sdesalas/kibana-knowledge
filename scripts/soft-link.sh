
##
# Add .knowledge folder to every kibana folder so you
# can reutilize md files with knowledge across all your
# kibana folders.
#

# One-time setup (if not already configured)
git config --global core.excludesFile ~/.gitignore_global

# Then add the pattern
echo ".knowledge" >> ~/.gitignore_global

# Then for every kibana folder do the following
# Link ./kibana-x/.knowledge -> ./kibana-knowledge repo
ln -s ../kibana-knowledge .knowledge

