<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
	<xsl:output method="xml" indent="yes" encoding="UTF-8"/>

	<xsl:template match="/plist">
		<xsl:text disable-output-escaping="yes">&lt;!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"&gt;
</xsl:text>
		<xsl:apply-templates select="//key[text()='LSHandlers']"/>
	</xsl:template>

	<xsl:template match="key">
		<plist version="1.0">
		<dict>
		<key>DUTISettings</key>
		<array>
		<xsl:for-each select="//key[text()='LSHandlerURLScheme']|//key[text()='LSHandlerContentType']">
			<dict>
			<key>DUTIBundleIdentifier</key>
			<xsl:if test="preceding-sibling::key[substring(text(),1,13)='LSHandlerRole']">
				<string><xsl:value-of select="preceding-sibling::string[preceding-sibling::key[substring(text(),1,13)='LSHandlerRole']]"/></string>
			</xsl:if>
			<xsl:if test="following-sibling::key[substring(text(),1,13)='LSHandlerRole']">
				<string><xsl:value-of select="following-sibling::string[preceding-sibling::key[substring(text(),1,13)='LSHandlerRole']]"/></string>
			</xsl:if>
			<xsl:choose>
				<xsl:when test="text()='LSHandlerURLScheme'">
					<key>DUTIURLScheme</key>
					<string><xsl:value-of select="following-sibling::string"/></string>
				</xsl:when>
				<xsl:when test="text()='LSHandlerContentType'">
					<key>DUTIUniformTypeIdentifier</key>
					<string><xsl:value-of select="following-sibling::string"/></string>
					<key>DUTIRole</key>
					<string><xsl:choose>
						<xsl:when test="preceding-sibling::key[text()='LSHandlerRoleAll']|following-sibling::key[text()='LSHandlerRoleAll']">all</xsl:when>
						<xsl:when test="preceding-sibling::key[text()='LSHandlerRoleViewer']|following-sibling::key[text()='LSHandlerRoleViewer']">viewer</xsl:when>
						<xsl:when test="preceding-sibling::key[text()='LSHandlerRoleEditor']|following-sibling::key[text()='LSHandlerRoleEditor']">editor</xsl:when>
						<xsl:when test="preceding-sibling::key[text()='LSHandlerRoleShell']|following-sibling::key[text()='LSHandlerRoleShell']">shell</xsl:when>
						<xsl:otherwise>none</xsl:otherwise>
					</xsl:choose></string>
				</xsl:when>
			</xsl:choose>
			</dict>
		</xsl:for-each>
		</array>
		</dict>
		</plist>
	</xsl:template>
</xsl:stylesheet>