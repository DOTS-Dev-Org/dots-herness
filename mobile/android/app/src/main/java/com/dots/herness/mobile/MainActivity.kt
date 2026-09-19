package com.dots.herness.mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private var pendingPairUri by mutableStateOf<Uri?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingPairUri = intent.data
        enableEdgeToEdge()
        setContent { MaterialTheme { HerNessApp(pendingPairUri) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingPairUri = intent.data
    }
}

@Composable
private fun HerNessApp(initialPairUri: Uri? = null) {
    val baseContext = LocalContext.current
    val preferences = remember { baseContext.getSharedPreferences("herness.preferences", Activity.MODE_PRIVATE) }
    var selectedLanguageCode by remember { mutableStateOf(preferences.mobileLanguage().code) }
    val selectedLanguage = MobileLanguages.fromCode(selectedLanguageCode)
    val effectiveLanguage = MobileLanguages.effective(selectedLanguage)
    val localizedContext = remember(selectedLanguage.code, effectiveLanguage.code) {
        baseContext.createMobileLocaleContext(effectiveLanguage)
    }

    CompositionLocalProvider(
        LocalContext provides localizedContext,
        LocalLayoutDirection provides if (effectiveLanguage.isRtl) LayoutDirection.Rtl else LayoutDirection.Ltr,
    ) {
    val context = LocalContext.current
    val client = remember { RemoteClient(context.applicationContext) }
    var hasSeenIntro by remember { mutableStateOf(preferences.getBoolean("has_seen_intro", false)) }
    var confirmBeforeExit by remember { mutableStateOf(preferences.getBoolean("confirm_before_exit", true)) }
    var showingSplash by remember { mutableStateOf(true) }
    val stateStore = remember { MobileStateStore(context.applicationContext) }
    val legal = remember { LegalModel(baseContext.applicationContext) }
    LaunchedEffect(effectiveLanguage.code) {
        legal.setLanguage(effectiveLanguage.code)
        legal.load()
    }
    val git = remember { MobileGitClient({ client.workspaceRoot() }, { client.phoneSecret("oauth.github.access") }) }
    val agent = remember { MobileHarnessRuntime({ client.phoneSecret("provider") }, { PHONE_AGENT_SYSTEM_PROMPT }, stateStore, { client.phoneSecret("oauth.openai.access") }, { client.phoneSecret("oauth.openai.account") }, { AgentTools.snapshot(client.workspaceRoot()) }, git) }
    val githubOAuth = remember { GitHubOAuth(context.applicationContext) }
    val chatGPTOAuth = remember { ChatGPTOAuth(context.applicationContext) }
    val shell = remember { LocalShell { client.workspaceRoot() } }
    val plugins = remember { Plugins { client.workspaceRoot() } }
    val loops = remember {
        LoopScheduler(context.applicationContext) {
            val loopGit = MobileGitClient({ client.workspaceRoot() }, { client.phoneSecret("oauth.github.access") })
            MobileAgent(
                { client.phoneSecret("provider") },
                { PHONE_AGENT_SYSTEM_PROMPT },
                oauthToken = { client.phoneSecret("oauth.openai.access") },
                sessionAccountId = { client.phoneSecret("oauth.openai.account") },
                workspaceSnapshotProvider = { AgentTools.snapshot(client.workspaceRoot()) },
                gitClient = loopGit,
            ).apply {
                register(AgentTools.workspace { client.workspaceRoot() })
                register(AgentTools.runtime(LocalShell { client.workspaceRoot() }, { client.workspaceRoot() }, loopGit))
                register(Plugins { client.workspaceRoot() }.reload())
            }
        }
    }
    val mcp = remember { McpRegistry(java.io.File(context.filesDir, "herness-workspace/meta/mcp.json"), SecureStore(context.applicationContext)) }
    LaunchedEffect(Unit) {
        chatGPTOAuth.refreshIfNeeded()
        agent.start()
        agent.register(AgentTools.workspace { client.workspaceRoot() })
        agent.register(AgentTools.runtime(shell, { client.workspaceRoot() }, git))
        agent.register(plugins.reload())
        agent.pluginPrompt = plugins.promptSections.joinToString("\n")
        mcp.connectAll(agent)
        loops.schedule()
        // Exact while the app is open; WorkManager takes over in the background.
        while (true) { loops.runDue(); kotlinx.coroutines.delay(30_000) }
    }
    LaunchedEffect(initialPairUri) {
        initialPairUri?.let { if (!githubOAuth.handleCallback(it) && !chatGPTOAuth.handleCallback(it)) client.consumePairUri(it) }
    }
    LaunchedEffect(Unit) {
        delay(900)
        showingSplash = false
    }
    if (showingSplash) {
        SplashScreen()
    } else if (!hasSeenIntro) {
        IntroScreen(
            selectedLanguage = selectedLanguage,
            onLanguageChange = { language ->
                selectedLanguageCode = language.code
                preferences.setMobileLanguage(language)
            },
        ) {
            preferences.edit().putBoolean("has_seen_intro", true).apply()
            hasSeenIntro = true
        }
    } else if (legal.needsAcceptance) {
        LegalGate(legal)
    } else {
        WorkspaceShell(
            client, agent, shell, plugins, mcp, loops, githubOAuth, chatGPTOAuth,
            legal = legal,
            confirmBeforeExit = confirmBeforeExit,
            selectedLanguage = selectedLanguage,
            onLanguageChange = { language ->
                selectedLanguageCode = language.code
                preferences.setMobileLanguage(language)
            },
            onConfirmBeforeExitChange = { value ->
                preferences.edit().putBoolean("confirm_before_exit", value).apply()
                confirmBeforeExit = value
            },
        )
    }
    }
}

internal val PHONE_AGENT_SYSTEM_PROMPT: String = HerNessPrompt.PHONE
internal const val MOBILE_LANGUAGE_KEY: String = "mobile.language"

private data class IntroSlide(val image: Int, val eyebrowKey: String, val titleKey: String, val descriptionKey: String)

private val introSlides = listOf(
    IntroSlide(R.drawable.intro_connect, "intro_eyebrow_connect", "intro_title_connect", "intro_description_connect"),
    IntroSlide(R.drawable.intro_agent, "intro_eyebrow_agent", "intro_title_agent", "intro_description_agent"),
    IntroSlide(R.drawable.intro_ship, "intro_eyebrow_ship", "intro_title_ship", "intro_description_ship")
)

@Composable
private fun SplashScreen() {
    val context = LocalContext.current

    DisposableEffect(context) {
        val controller = (context as? Activity)?.window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        controller?.isAppearanceLightStatusBars = true
        controller?.isAppearanceLightNavigationBars = true
        onDispose { }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFFFFFCEF)),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Image(
                painter = painterResource(R.mipmap.ic_launcher),
                contentDescription = stringResource(R.string.mobile_splash_logo),
                modifier = Modifier.size(184.dp),
                contentScale = ContentScale.Fit
            )
            Text(
                "HerNess",
                color = Color(0xFF261C14),
                fontSize = 34.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = (-0.5).sp
            )
            Text(
                stringResource(R.string.mobile_splash_build_line),
                color = Color.Black.copy(alpha = 0.52f),
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.2.sp,
                modifier = Modifier.padding(top = 16.dp)
            )
        }
    }
}

@Composable
private fun IntroScreen(
    selectedLanguage: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    onFinish: () -> Unit,
) {
    val context = LocalContext.current
    val layoutDirection = LocalLayoutDirection.current
    val pagerState = rememberPagerState(pageCount = { introSlides.size })
    val scope = rememberCoroutineScope()

    DisposableEffect(context) {
        val controller = (context as? Activity)?.window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        controller?.isAppearanceLightStatusBars = false
        controller?.isAppearanceLightNavigationBars = false
        onDispose {
            controller?.isAppearanceLightStatusBars = true
            controller?.isAppearanceLightNavigationBars = true
        }
    }

    HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
        val slide = introSlides[page]
        val pageDescription = stringResource(R.string.intro_page, page + 1, introSlides.size)
        Box(Modifier.fillMaxSize()) {
            Image(
                painter = painterResource(slide.image),
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.08f), Color.Black.copy(alpha = 0.92f))))
            )
            Column(
                Modifier
                    .fillMaxSize()
                    .safeDrawingPadding()
                    .padding(horizontal = 24.dp, vertical = 16.dp)
            ) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("HerNess", color = Color.White, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.weight(1f))
                    if (layoutDirection == LayoutDirection.Rtl) {
                        if (page < introSlides.lastIndex) {
                            TextButton(onClick = onFinish, colors = ButtonDefaults.textButtonColors(contentColor = Color.White.copy(alpha = 0.8f))) {
                                Text(stringResource(R.string.intro_skip))
                            }
                        }
                        MobileLanguagePicker(selectedLanguage, onLanguageChange, darkAppearance = true)
                    } else {
                        MobileLanguagePicker(selectedLanguage, onLanguageChange, darkAppearance = true)
                        if (page < introSlides.lastIndex) {
                            TextButton(onClick = onFinish, colors = ButtonDefaults.textButtonColors(contentColor = Color.White.copy(alpha = 0.8f))) {
                                Text(stringResource(R.string.intro_skip))
                            }
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                Text(stringResource(resourceId(slide.eyebrowKey)), color = Color.White.copy(alpha = 0.68f), fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.5.sp)
                Text(
                    stringResource(resourceId(slide.titleKey)),
                    color = Color.White,
                    style = MaterialTheme.typography.displaySmall.copy(fontWeight = FontWeight.Bold),
                    modifier = Modifier.padding(top = 10.dp)
                )
                Text(
                    stringResource(resourceId(slide.descriptionKey)),
                    color = Color.White.copy(alpha = 0.76f),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.padding(top = 12.dp)
                )
                Row(
                    Modifier.padding(top = 24.dp).semantics { contentDescription = pageDescription },
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    introSlides.indices.forEach { index ->
                        Box(
                            Modifier
                                .height(8.dp)
                                .width(if (index == page) 26.dp else 8.dp)
                                .background(if (index == page) Color.White else Color.White.copy(alpha = 0.3f), RoundedCornerShape(50))
                        )
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    @Composable
                    fun BackButton() {
                        TextButton(
                            onClick = { scope.launch { pagerState.animateScrollToPage(page - 1) } },
                            modifier = Modifier.height(58.dp),
                            colors = ButtonDefaults.textButtonColors(contentColor = Color.White),
                        ) {
                            Text(if (layoutDirection == LayoutDirection.Rtl) "→" else "←", fontWeight = FontWeight.Bold)
                            Spacer(Modifier.width(6.dp))
                            Text(stringResource(R.string.intro_back))
                        }
                    }

                    @Composable
                    fun PrimaryButton() {
                        Button(
                            onClick = {
                                if (page == introSlides.lastIndex) onFinish() else scope.launch { pagerState.animateScrollToPage(page + 1) }
                            },
                            modifier = Modifier.weight(1f).height(58.dp),
                            shape = RoundedCornerShape(18.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color(0xFF0B0B16)),
                        ) {
                            Text(stringResource(if (page == introSlides.lastIndex) R.string.intro_start else R.string.intro_continue))
                            Spacer(Modifier.width(8.dp))
                            Text(if (layoutDirection == LayoutDirection.Rtl) "←" else "→", fontWeight = FontWeight.Bold)
                        }
                    }

                    if (page > 0 && layoutDirection == LayoutDirection.Rtl) {
                        PrimaryButton()
                        BackButton()
                    } else {
                        if (page > 0) BackButton()
                        PrimaryButton()
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

private fun resourceId(key: String): Int = when (key) {
    "intro_eyebrow_connect" -> R.string.intro_eyebrow_connect
    "intro_title_connect" -> R.string.intro_title_connect
    "intro_description_connect" -> R.string.intro_description_connect
    "intro_eyebrow_agent" -> R.string.intro_eyebrow_agent
    "intro_title_agent" -> R.string.intro_title_agent
    "intro_description_agent" -> R.string.intro_description_agent
    "intro_eyebrow_ship" -> R.string.intro_eyebrow_ship
    "intro_title_ship" -> R.string.intro_title_ship
    "intro_description_ship" -> R.string.intro_description_ship
    else -> error("Unknown intro resource: $key")
}

@Composable
private fun MobileLanguagePicker(
    selectedLanguage: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    darkAppearance: Boolean,
) {
    var showingLanguages by remember { mutableStateOf(false) }
    TextButton(
        onClick = { showingLanguages = true },
        colors = ButtonDefaults.textButtonColors(contentColor = if (darkAppearance) Color.White else MaterialTheme.colorScheme.primary),
    ) {
        Text("🌐 ${selectedLanguage.shortCode}", fontWeight = FontWeight.SemiBold)
    }
    if (showingLanguages) {
        AlertDialog(
            onDismissRequest = { showingLanguages = false },
            title = { Text(stringResource(R.string.intro_language)) },
            text = {
                LazyColumn(Modifier.height(420.dp)) {
                    items(MobileLanguages.all, key = { it.code }) { language ->
                        TextButton(
                            onClick = {
                                onLanguageChange(language)
                                showingLanguages = false
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text(language.flag)
                                Spacer(Modifier.width(12.dp))
                            Text(if (language.code == "system") stringResource(R.string.intro_language_system) else language.nativeName)
                                Spacer(Modifier.weight(1f))
                                if (selectedLanguage.code == language.code) Text("✓")
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton({ showingLanguages = false }) { Text(stringResource(R.string.app_ok)) } },
        )
    }
}

@Composable
private fun WorkspaceShell(
    client: RemoteClient,
    agent: MobileAgent,
    shell: LocalShell,
    plugins: Plugins,
    mcp: McpRegistry,
    loops: LoopScheduler,
    github: GitHubOAuth,
    chatGPT: ChatGPTOAuth,
    legal: LegalModel,
    selectedLanguage: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    confirmBeforeExit: Boolean,
    onConfirmBeforeExitChange: (Boolean) -> Unit,
) {
    var tab by remember { mutableIntStateOf(0) }
    var showingExitConfirmation by remember { mutableStateOf(false) }
    var rememberExit by remember { mutableStateOf(false) }
    val context = LocalContext.current

    fun closeApp() { (context as? Activity)?.finish() }
    fun requestExit() {
        if (confirmBeforeExit) {
            rememberExit = false
            showingExitConfirmation = true
        } else {
            closeApp()
        }
    }

    BackHandler { requestExit() }
    Scaffold(
        contentWindowInsets = androidx.compose.material3.ScaffoldDefaults.contentWindowInsets,
        bottomBar = {
            NavigationBar {
                val titles = listOf(
                    stringResource(R.string.mobile_nav_code),
                    stringResource(R.string.mobile_nav_agent),
                    stringResource(R.string.mobile_nav_terminal),
                    stringResource(R.string.mobile_nav_preview),
                    stringResource(R.string.mobile_nav_settings),
                )
                titles.forEachIndexed { index, title ->
                    NavigationBarItem(selected = tab == index, onClick = { tab = index }, icon = { Text(listOf("⌘", "✦", ">_", "◉", "⚙")[index]) }, label = { Text(title) })
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) { when (tab) { 0 -> CodeScreen { client.workspaceRoot() }; 1 -> AgentTab(agent); 2 -> TerminalTab(client); 3 -> PreviewScreen(); else -> SettingsScreen(client, agent, plugins, mcp, loops, github, chatGPT, legal, selectedLanguage, onLanguageChange, confirmBeforeExit, onConfirmBeforeExitChange, ::requestExit) } }
    }
    if (showingExitConfirmation) AlertDialog(
        onDismissRequest = { showingExitConfirmation = false },
        title = { Text(stringResource(R.string.mobile_exit_title)) },
        text = {
            Column {
                Text(stringResource(R.string.mobile_exit_message))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(rememberExit, { rememberExit = it })
                    Text(stringResource(R.string.mobile_exit_remember))
                }
            }
        },
        confirmButton = {
        TextButton({
                showingExitConfirmation = false
                if (rememberExit) onConfirmBeforeExitChange(false)
                closeApp()
            }) { Text(stringResource(R.string.mobile_exit_confirm)) }
        },
        dismissButton = { TextButton({ showingExitConfirmation = false }) { Text(stringResource(R.string.mobile_exit_cancel)) } },
    )
}

@Composable
private fun CodeScreen(root: () -> java.io.File) {
    var files by remember { mutableStateOf<List<String>>(emptyList()) }
    var selected by remember { mutableStateOf<String?>(null) }
    var text by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val savedLocalMessage = stringResource(R.string.mobile_workspace_saved_local)
    val saveFailedMessage = stringResource(R.string.mobile_workspace_save_failed)

    fun refresh() {
        scope.launch { files = withContext(Dispatchers.IO) { AgentTools.walk(root()) } }
    }

    LaunchedEffect(Unit) { refresh() }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Button({ refresh() }) { Text(stringResource(R.string.common_refresh)) }
            Text(stringResource(R.string.mobile_workspace_local), style = MaterialTheme.typography.bodySmall)
        }
        HorizontalDivider()
        Row(Modifier.fillMaxSize()) {
            LazyColumn(Modifier.weight(0.38f)) {
                items(files, key = { it }) { path ->
                    TextButton({
                        selected = path
                        scope.launch {
                            text = withContext(Dispatchers.IO) { runCatching { AgentTools.resolve(root(), path).readText() }.getOrDefault("") }
                            message = null
                        }
                    }, Modifier.fillMaxWidth()) { Text(path) }
                }
            }
            Column(Modifier.weight(0.62f).fillMaxSize().padding(8.dp)) {
                Text(selected ?: stringResource(R.string.mobile_workspace_select_file), style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(text, { text = it }, Modifier.weight(1f).fillMaxWidth(), textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace), label = { Text(stringResource(R.string.mobile_workspace_code_editor)) }, enabled = selected != null)
                selected?.let { path ->
                    Button({
                        scope.launch {
                            message = runCatching {
                                withContext(Dispatchers.IO) {
                                    val file = AgentTools.resolve(root(), path)
                                    file.parentFile?.mkdirs()
                                    file.writeText(text)
                                }
                                refresh()
                                savedLocalMessage
                            }.getOrElse { it.message ?: saveFailedMessage }
                        }
                    }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.mobile_workspace_save)) }
                }
                message?.let { Text(it, color = if (it.contains("failed", true)) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 6.dp)) }
            }
        }
    }
}


/**
 * The Agent tab runs entirely through the on-device runtime.
 */
@Composable
private fun AgentTab(agent: MobileAgent) { LocalAgentScreen(agent) }

@Composable
private fun LocalAgentScreen(agent: MobileAgent) {
    var prompt by remember { mutableStateOf("") }
    var questionAnswer by remember { mutableStateOf("") }
    var showModels by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton({ showModels = true }) { Text(agent.model) }
            TextButton({ agent.reset() }) { Text(stringResource(R.string.mobile_agent_new_conversation)) }
            Switch(checked = agent.planMode, onCheckedChange = { agent.planMode = it })
            Text(stringResource(R.string.mobile_agent_plan), style = MaterialTheme.typography.labelSmall)
        }
        LazyColumn(Modifier.weight(1f)) {
            items(agent.transcript) { turn ->
                Column(Modifier.padding(10.dp)) {
                    Text(
                        when (turn.role) {
                            "user" -> stringResource(R.string.mobile_agent_user)
                            "assistant" -> stringResource(R.string.conversation_assistant)
                            "tool" -> turn.toolName ?: stringResource(R.string.conversation_tool)
                            "system" -> stringResource(R.string.mobile_event_run_summary)
                            else -> stringResource(R.string.mobile_agent_error)
                        },
                        style = MaterialTheme.typography.labelMedium,
                        color = when (turn.role) { "error" -> MaterialTheme.colorScheme.error; "assistant" -> MaterialTheme.colorScheme.primary; "system" -> MaterialTheme.colorScheme.secondary; else -> MaterialTheme.colorScheme.onSurfaceVariant },
                    )
                    Text(turn.text, fontFamily = if (turn.role == "tool") FontFamily.Monospace else FontFamily.Default, maxLines = if (turn.role == "tool") 12 else Int.MAX_VALUE)
                }
            }
        }
        agent.approvalRequest?.let { approval ->
            Column(Modifier.fillMaxWidth().padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.mobile_agent_approval_required), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(R.string.mobile_agent_allow_tool).replace("%@", approval.toolName))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button({ agent.answerApproval(approval.id, true) }) { Text(stringResource(R.string.permission_allow_once)) }
                    TextButton({ agent.answerApproval(approval.id, false) }) { Text(stringResource(R.string.permission_reject)) }
                }
            }
        }
        agent.questionRequest?.let { question ->
            Column(Modifier.fillMaxWidth().padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.mobile_agent_clarification), style = MaterialTheme.typography.titleSmall)
                Text(question.question)
                OutlinedTextField(questionAnswer, { questionAnswer = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_agent_answer)) })
                Button({
                    val answer = questionAnswer
                    questionAnswer = ""
                    agent.answerQuestion(question.id, listOf(answer))
                }, enabled = questionAnswer.isNotBlank()) { Text(stringResource(R.string.mobile_agent_answer)) }
            }
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp).height(110.dp).verticalScroll(rememberScrollState())) {
            Text(stringResource(R.string.mobile_agent_event_history), style = MaterialTheme.typography.labelMedium)
            agent.events.takeLast(30).forEach { event ->
                Text(event.kind + " " + (event.payload["preview"] ?: event.payload["text"].orEmpty()), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall)
            }
        }
        Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(prompt, { prompt = it }, Modifier.weight(1f), label = { Text(stringResource(R.string.mobile_agent_ask)) })
            if (agent.running) {
                Button({ agent.send(prompt, "queue", agent.planMode); prompt = "" }, enabled = prompt.isNotBlank()) { Text(stringResource(R.string.mobile_agent_queue)) }
                TextButton({ agent.send(prompt, "steer", agent.planMode); prompt = "" }, enabled = prompt.isNotBlank()) { Text(stringResource(R.string.conversation_steer)) }
                Button({ agent.cancel() }) { Text(stringResource(R.string.common_stop)) }
            } else {
                Button({ agent.send(prompt, "queue", agent.planMode); prompt = "" }, enabled = prompt.isNotBlank()) { Text(stringResource(R.string.mobile_agent_send)) }
            }
        }
        agent.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 8.dp)) }
    }
    if (showModels) AlertDialog(
        onDismissRequest = { showModels = false },
        title = { Text(stringResource(R.string.mobile_agent_model)) },
        text = { Column { MobileAgent.MODELS.forEach { value -> TextButton({ agent.selectModel(value); showModels = false }) { Text(value) } } } },
        confirmButton = { TextButton({ showModels = false }) { Text(stringResource(R.string.mobile_agent_close)) } },
    )
}

/** Terminal tab: the constrained mobile runtime, never an implicit desktop shell. */
@Composable
private fun TerminalTab(client: RemoteClient) {
    PhoneTerminalScreen(LocalShell { client.workspaceRoot() })
}

@Composable
private fun PhoneTerminalScreen(shell: LocalShell) {
    var command by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth().background(Color(0xFF0B0B0B)).padding(8.dp)) {
            items(shell.lines) { line -> Text(line, fontFamily = FontFamily.Monospace, color = Color(0xFF4CE04C), style = MaterialTheme.typography.bodySmall) }
        }
        Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(shell.prompt, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(command, { command = it }, Modifier.weight(1f), label = { Text("ls -l") }, textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
            Button({ val value = command; command = ""; scope.launch { shell.run(value) } }, enabled = command.isNotBlank()) { Text(stringResource(R.string.mobile_terminal_run)) }
        }
    }
}

@Composable
private fun PreviewScreen() {
    var url by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(8.dp)) {
        OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_preview_url)) })
        if (url.startsWith("http")) {
            AndroidView({ context -> WebView(context).apply { webViewClient = WebViewClient(); settings.javaScriptEnabled = true } }, Modifier.fillMaxSize()) { it.loadUrl(url) }
        } else {
            Text(stringResource(R.string.mobile_preview_pages_hint), Modifier.padding(12.dp))
        }
    }
}


/** MCP servers and JS plugins: both extend the phone agent's tool set. */

@Composable
private fun LoopsSection(loops: LoopScheduler) {
    var name by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    var minutes by remember { mutableStateOf("60") }
    val scope = rememberCoroutineScope()

    Text(stringResource(R.string.mobile_loops_title), style = MaterialTheme.typography.titleMedium)
    loops.loops.forEach { loop ->
        Column(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(loop.name, Modifier.weight(1f))
                Switch(loop.enabled, { loops.setEnabled(loop, it) })
                TextButton({ loops.remove(loop) }) { Text(stringResource(R.string.common_remove)) }
            }
            val lastRun = if (loop.lastRun > 0) stringResource(R.string.mobile_loops_last_run).replace("%@", java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(loop.lastRun))) else ""
            Text(
                stringResource(R.string.mobile_loops_every).replace("%d", loop.minutes.toString()) + lastRun,
                style = MaterialTheme.typography.bodySmall,
            )
            if (loop.lastResult.isNotBlank()) Text(loop.lastResult.take(300), style = MaterialTheme.typography.bodySmall)
            TextButton({ scope.launch { loops.run(loop) } }, enabled = loops.running == null) { Text(stringResource(R.string.mobile_loops_run_now)) }
        }
    }
    OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.tasks_field_name)) })
    OutlinedTextField(prompt, { prompt = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.loop_instruction_label)) })
    OutlinedTextField(minutes, { minutes = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.loop_minutes_label)) })
    Button({ loops.add(name, prompt, minutes.toIntOrNull() ?: 60); name = ""; prompt = ""; minutes = "60" }, enabled = prompt.isNotBlank()) { Text(stringResource(R.string.mobile_loops_add)) }
    Text(stringResource(R.string.mobile_loops_background_hint), style = MaterialTheme.typography.bodySmall)
}

@Composable
private fun McpAndPluginsSection(agent: MobileAgent, plugins: Plugins, mcp: McpRegistry) {
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    var token by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    Text(stringResource(R.string.mobile_mcp_title), style = MaterialTheme.typography.titleMedium)
    mcp.servers.forEach { server ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(server.name)
                Text(mcp.status[server.id] ?: server.url, style = MaterialTheme.typography.bodySmall)
            }
            TextButton({ mcp.remove(server) }) { Text(stringResource(R.string.common_remove)) }
        }
    }
    OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.tasks_field_name)) })
    OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text("https://example.com/mcp") })
    OutlinedTextField(token, { token = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_mcp_bearer_token)) })
    Button({ mcp.add(name, url, token); name = ""; url = ""; token = ""; scope.launch { mcp.connectAll(agent) } }, enabled = url.isNotBlank()) { Text(stringResource(R.string.mobile_mcp_add)) }
    Button({ scope.launch { mcp.connectAll(agent) } }) { Text(stringResource(R.string.mobile_mcp_reconnect)) }
    Text(stringResource(R.string.mobile_mcp_https_hint), style = MaterialTheme.typography.bodySmall)

    Text(stringResource(R.string.settings_plugins_title), style = MaterialTheme.typography.titleMedium)
    if (plugins.loaded.isEmpty() && plugins.failures.isEmpty()) {
        Text(stringResource(R.string.mobile_plugins_empty_hint), style = MaterialTheme.typography.bodySmall)
    }
    plugins.loaded.forEach { manifest ->
        Column { Text("${manifest.name} ${manifest.version}"); if (manifest.description.isNotBlank()) Text(manifest.description, style = MaterialTheme.typography.bodySmall) }
    }
    plugins.failures.forEach { (id, message) ->
        Column { Text(id, color = MaterialTheme.colorScheme.error); Text(message, style = MaterialTheme.typography.bodySmall) }
    }
    Button({ agent.register(plugins.reload()); agent.pluginPrompt = plugins.promptSections.joinToString("\n") }) { Text(stringResource(R.string.mobile_plugins_reload)) }
}

@Composable
private fun SettingsScreen(
    client: RemoteClient,
    agent: MobileAgent,
    plugins: Plugins,
    mcp: McpRegistry,
    loops: LoopScheduler,
    github: GitHubOAuth,
    chatGPT: ChatGPTOAuth,
    legal: LegalModel,
    selectedLanguage: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    confirmBeforeExit: Boolean,
    onConfirmBeforeExitChange: (Boolean) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val settingsScroll = rememberScrollState()
    var providerKey by remember { mutableStateOf(client.phoneSecret("provider")) }
    
    var owner by remember { mutableStateOf(client.repo.owner) }
    var repository by remember { mutableStateOf(client.repo.repository) }
    var base by remember { mutableStateOf(client.repo.branch) }
    var repoSlug by remember { mutableStateOf(client.repo.slug.takeIf { client.repo.complete } ?: "") }
    var branch by remember { mutableStateOf("herness/mobile-${System.currentTimeMillis()}") }
    var githubStatus by remember { mutableStateOf("") }
    var repositories by remember { mutableStateOf<List<GitHubRepository>>(emptyList()) }
    var branches by remember { mutableStateOf<List<String>>(emptyList()) }
    val scope = rememberCoroutineScope()
    val githubRequestFailed = stringResource(R.string.mobile_settings_request_failed)
    val repositoryInputError = stringResource(R.string.mobile_settings_repository_input_error)

    Column(Modifier.fillMaxSize().verticalScroll(settingsScroll).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.intro_language), style = MaterialTheme.typography.titleMedium)
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(if (selectedLanguage.code == "system") stringResource(R.string.intro_language_system) else selectedLanguage.nativeName, Modifier.weight(1f))
            MobileLanguagePicker(selectedLanguage, onLanguageChange, darkAppearance = false)
        }
        Text(stringResource(R.string.settings_tab_providers), style = MaterialTheme.typography.headlineSmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button({ agent.selectProvider("anthropic") }, enabled = agent.provider != "anthropic") { Text("Anthropic") }
            Button({ agent.selectProvider("openai") }, enabled = agent.provider != "openai") { Text("OpenAI") }
            Button({ agent.selectProvider("openai-responses") }, enabled = agent.provider != "openai-responses") { Text("Responses") }
            Button({ agent.selectProvider("gpt") }, enabled = agent.provider != "gpt") { Text("GPT") }
        }
        Text(stringResource(R.string.model_picker_model) + ": " + agent.model, style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_phone_accounts), style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(providerKey, { providerKey = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_settings_provider_key)) })
        Button({ client.savePhoneSecret("provider", providerKey) }) { Text(stringResource(R.string.mobile_settings_save_provider_key)) }
        Text(stringResource(R.string.mobile_settings_provider_key_hint), style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_gpt_account), style = MaterialTheme.typography.titleMedium)
        if (chatGPT.accessToken.isBlank()) {
            Button({ chatGPT.start(context as? Activity) }, enabled = !chatGPT.signingIn) { Text(if (chatGPT.signingIn) stringResource(R.string.mobile_settings_waiting_chat_gpt) else stringResource(R.string.mobile_settings_sign_in_chat_gpt)) }
        } else {
            Text("ChatGPT " + stringResource(R.string.mobile_settings_connected), color = MaterialTheme.colorScheme.primary)
            TextButton({ chatGPT.signOut() }) { Text(stringResource(R.string.mobile_settings_sign_out)) }
        }
        if (chatGPT.status.isNotBlank()) Text(chatGPT.status, style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_gpt_hint), style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_github_account), style = MaterialTheme.typography.titleMedium)
        if (github.accessToken.isBlank()) {
            Button({ github.start(context as? Activity) }, enabled = !github.signingIn) { Text(if (github.signingIn) stringResource(R.string.mobile_settings_waiting_git_hub) else stringResource(R.string.mobile_settings_sign_in_git_hub)) }
        } else {
            Text("GitHub " + stringResource(R.string.mobile_settings_connected), color = MaterialTheme.colorScheme.primary)
            TextButton({ github.signOut() }) { Text(stringResource(R.string.mobile_settings_sign_out)) }
        }
        if (github.status.isNotBlank()) Text(github.status, style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_github_hint), style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_offline_repository), style = MaterialTheme.typography.titleMedium)
        Button({ scope.launch { repositories = runCatching { GitHubClient(github.accessToken).repositories() }.getOrElse { githubStatus = it.message ?: githubRequestFailed; emptyList() } } }, enabled = github.accessToken.isNotBlank()) { Text(stringResource(R.string.mobile_settings_load_repositories)) }
        repositories.forEach { item ->
            TextButton({
                repoSlug = item.fullName
                owner = item.owner
                repository = item.name
                base = item.defaultBranch
                scope.launch { branches = runCatching { GitHubClient(github.accessToken).branches(item.owner, item.name) }.getOrDefault(emptyList()) }
            }, Modifier.fillMaxWidth()) { Text(item.fullName + " · " + item.defaultBranch) }
        }
        if (repositories.isEmpty()) OutlinedTextField(repoSlug, { repoSlug = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_settings_owner_repository)) })
        if (branches.isNotEmpty()) {
            branches.forEach { value -> TextButton({ base = value }) { Text(value) } }
        } else {
            OutlinedTextField(base, { base = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_settings_branch)) })
        }
        Button(
            {
                val target = RepoCoordinates.parse(repoSlug, base.ifBlank { "main" })
                if (target == null) githubStatus = repositoryInputError
                else { owner = target.owner; repository = target.repository; agent.selectRepository(target); client.cloneFromGitHub(target, github.accessToken) }
            },
            enabled = github.accessToken.isNotBlank() && repoSlug.isNotBlank(),
        ) { Text(stringResource(R.string.mobile_settings_clone)) }
        if (client.cloneStatus.isNotBlank()) Text(client.cloneStatus, style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_selected_branch_hint), style = MaterialTheme.typography.bodySmall)
        Text(stringResource(R.string.mobile_settings_github_changes), style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(owner, { owner = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_settings_owner)) })
        OutlinedTextField(repository, { repository = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_settings_repository)) })
        OutlinedTextField(branch, { branch = it }, Modifier.fillMaxWidth(), label = { Text(stringResource(R.string.mobile_settings_new_branch)) })
        Button(
            {
                scope.launch {
                    val changes = client.cachedChanges()
                    githubStatus = if (changes.isEmpty()) "No local mirror changes to commit." else runCatching {
                        GitHubClient(github.accessToken).commitAndOpenPullRequest(owner, repository, base, branch.ifBlank { "herness/mobile-${System.currentTimeMillis()}" }, "Update from HerNess mobile", changes, "HerNess mobile changes", "Created from the HerNess offline workspace mirror.")
                    }.getOrElse { it.message ?: "GitHub request failed." }
                }
            },
            enabled = github.accessToken.isNotBlank() && owner.isNotBlank() && repository.isNotBlank(),
        ) { Text(stringResource(R.string.mobile_settings_commit_pr)) }
        if (githubStatus.isNotBlank()) Text(githubStatus, style = MaterialTheme.typography.bodySmall)
        LoopsSection(loops)
        McpAndPluginsSection(agent, plugins, mcp)
        Text(stringResource(R.string.mobile_exit_settings_section), style = MaterialTheme.typography.titleMedium)
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.mobile_exit_ask_before_exit))
                Text(stringResource(R.string.mobile_exit_settings_hint), style = MaterialTheme.typography.bodySmall)
            }
            Switch(checked = confirmBeforeExit, onCheckedChange = onConfirmBeforeExitChange)
        }
        Button(onClick = onExit, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) {
            Text(stringResource(R.string.mobile_exit_action_label))
        }
        Text(stringResource(R.string.mobile_settings_build_hint), style = MaterialTheme.typography.bodySmall)
        client.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        HorizontalDivider(Modifier.padding(vertical = 8.dp))
        LegalSettingsSection(legal)
    }
}
