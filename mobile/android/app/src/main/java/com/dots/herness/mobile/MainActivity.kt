package com.dots.herness.mobile

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.speech.RecognizerIntent
import org.json.JSONObject
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.WindowCompat
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.Modifier
import androidx.compose.ui.zIndex
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.ui.viewinterop.AndroidView
import java.net.URI
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import androidx.compose.runtime.snapshotFlow
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker

private data class PendingAttentionNotification(
    val id: String,
    val title: String,
    val subtitle: String,
    val detail: String,
)

@Composable
private fun MobileProviderBrandMark(providerId: String, modifier: Modifier = Modifier.size(22.dp)) {
    val image = when (providerId.lowercase()) {
        "gpt", "openai", "openai-responses" -> R.drawable.provider_openai
        "anthropic", "claude" -> R.drawable.provider_anthropic
        else -> null
    }
    if (image != null) {
        Image(
            painter = painterResource(image),
            contentDescription = null,
            modifier = modifier.background(Color.White, RoundedCornerShape(6.dp)).padding(3.dp),
            contentScale = ContentScale.Fit,
        )
    } else {
        Text("◉", modifier = modifier, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

class MainActivity : ComponentActivity() {
    private var pendingPairUri by mutableStateOf<Uri?>(null)
    internal var lifecycleAgent: MobileAgent? = null
    private val playUpdates = PlayUpdates(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingPairUri = intent.data
        enableEdgeToEdge()
        if (savedInstanceState == null) playUpdates.checkOnLaunch()
        setContent {
            val baseContext = LocalContext.current
            val preferences = remember { baseContext.getSharedPreferences("herness.preferences", Activity.MODE_PRIVATE) }
            var isDarkTheme by remember { mutableStateOf(preferences.getBoolean("mobile.theme.dark", true)) }
            MaterialTheme(colorScheme = if (isDarkTheme) darkColorScheme() else lightColorScheme()) {
                HerNessApp(
                    initialPairUri = pendingPairUri,
                    isDarkTheme = isDarkTheme,
                    onThemeToggle = {
                        val next = !isDarkTheme
                        isDarkTheme = next
                        preferences.edit().putBoolean("mobile.theme.dark", next).apply()
                    }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingPairUri = intent.data
    }

    override fun onResume() {
        super.onResume()
        playUpdates.resume()
    }

    override fun onDestroy() {
        playUpdates.close()
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        lifecycleAgent?.resumeRecoveredConversationIfNeeded()
    }

    override fun onStop() {
        // Android can kill a stopped process without giving the agent another
        // chance to observe a provider/tool result.
        lifecycleAgent?.pauseForLifecycleInterruption()
        super.onStop()
    }
}

@Composable
private fun HerNessApp(
    initialPairUri: Uri? = null,
    isDarkTheme: Boolean = true,
    onThemeToggle: () -> Unit = {},
) {
    val baseContext = LocalContext.current
    val preferences = remember { baseContext.getSharedPreferences("herness.preferences", Activity.MODE_PRIVATE) }
    var selectedLanguageCode by remember { mutableStateOf(preferences.mobileLanguage().code) }
    val selectedLanguage = MobileLanguages.fromCode(selectedLanguageCode)
    val effectiveLanguage = MobileLanguages.effective(selectedLanguage)
    val activity = baseContext.findActivity() as? ComponentActivity
        ?: error("HerNessApp must be hosted by a ComponentActivity")
    val localizedContext = remember(selectedLanguage.code, effectiveLanguage.code) {
        baseContext.createMobileLocaleContext(effectiveLanguage)
    }

    CompositionLocalProvider(
        LocalContext provides localizedContext,
        LocalActivityResultRegistryOwner provides (activity as ActivityResultRegistryOwner),
        LocalOnBackPressedDispatcherOwner provides activity,
        LocalLayoutDirection provides if (effectiveLanguage.isRtl) LayoutDirection.Rtl else LayoutDirection.Ltr,
    ) {
    val context = LocalContext.current
    val client = remember { RemoteClient(context.applicationContext) }
    var hasSeenIntro by remember { mutableStateOf(preferences.getBoolean("has_seen_intro", false)) }
    var confirmBeforeExit by remember { mutableStateOf(preferences.getBoolean("confirm_before_exit", true)) }
    var showingSplash by remember { mutableStateOf(true) }
    val stateStore = remember { MobileStateStore(context.applicationContext) }
    val personalMemoryRoot = remember { java.io.File(context.filesDir, "herness-memory") }
    val legal = remember { LegalModel(baseContext.applicationContext) }
    LaunchedEffect(effectiveLanguage.code) {
        legal.setLanguage(effectiveLanguage.code)
        legal.load()
    }
    val storedProvider = stateStore.setting("herness.agent.provider")
    val migrationProvider = storedProvider?.takeIf { MobileHarnessRuntime.definition(it)?.requiresApiKey == true } ?: "anthropic"
    remember(migrationProvider) { client.migrateLegacyProviderKey(migrationProvider) }
    val git = remember { MobileGitClient({ client.workspaceRoot() }, { client.phoneSecret("oauth.github.access") }) }
    val githubOAuth = remember { GitHubOAuth(context.applicationContext) }
    val chatGPTOAuth = remember { ChatGPTOAuth(context.applicationContext) }
    val agent = remember {
        MobileHarnessRuntime(
            { "" },
            { PHONE_AGENT_SYSTEM_PROMPT },
            stateStore,
            { chatGPTOAuth.accessToken },
            { chatGPTOAuth.roomiestAccountId() },
            { AgentTools.snapshot(client.workspaceRoot()) },
            git,
            context.applicationContext,
            providerApiKey = { provider -> client.phoneSecret("provider.$provider") },
            isProjectLocationAvailable = { client.projectLocationAvailableNow },
            oauthTokenForAccount = { id -> chatGPTOAuth.accessTokenFor(id) },
            chatGPTAccountIDs = { chatGPTOAuth.accountIDs() },
        )
    }
    DisposableEffect(agent, baseContext) {
        val activity = baseContext as? MainActivity
        activity?.lifecycleAgent = agent
        onDispose {
            if (activity?.lifecycleAgent === agent) activity.lifecycleAgent = null
        }
    }
    val shell = remember { LocalShell { client.workspaceRoot() } }
    val plugins = remember { Plugins { client.workspaceRoot() } }
    val loops = remember {
        LoopScheduler(context.applicationContext) {
            // Capture the project scope at the moment the scheduled run starts.
            // A later project selection must not retarget this run's tools.
            val loopProjectID = client.selectedProjectId
            val loopRoot = client.workspaceRoot()
            val loopShell = LocalShell { loopRoot }
            val loopGit = MobileGitClient({ loopRoot }, { client.phoneSecret("oauth.github.access") })
            MobileAgent(
                { "" },
                { PHONE_AGENT_SYSTEM_PROMPT },
                stateStore,
                oauthToken = { chatGPTOAuth.accessToken },
                sessionAccountId = { chatGPTOAuth.roomiestAccountId() },
                workspaceSnapshotProvider = { AgentTools.snapshot(loopRoot) },
                gitClient = loopGit,
                providerApiKey = { provider -> client.phoneSecret("provider.$provider") },
                isProjectLocationAvailable = { java.io.File(loopRoot.path).isDirectory },
                oauthTokenForAccount = { id -> chatGPTOAuth.accessTokenFor(id) },
                chatGPTAccountIDs = { chatGPTOAuth.accountIDs() },
            ).apply {
                selectProject(loopProjectID)
                register(WebTools.specs())
                register(AgentTools.workspace({ loopRoot }, { personalMemoryRoot }))
                learnedRules = { MobileLessons.rulesText(loopRoot, userRoot = personalMemoryRoot) }
                personalMemory = { MobilePersonalMemory.text(personalMemoryRoot, loopRoot) }
                register(AgentTools.runtime(loopShell, { loopRoot }, loopGit, client))
                replaceProjectTools(Plugins { loopRoot }.reload())
            }
        }
    }
    val mcp = remember { McpRegistry(java.io.File(context.filesDir, "herness-workspace/meta/mcp.json"), SecureStore(context.applicationContext)) }
    LaunchedEffect(Unit) {
        chatGPTOAuth.refreshIfNeeded()
        agent.selectProject(client.selectedProjectId)
        agent.register(WebTools.specs())
        agent.register(AgentTools.workspace({ client.workspaceRoot() }, { personalMemoryRoot }))
        agent.learnedRules = { MobileLessons.rulesText(client.workspaceRoot(), userRoot = personalMemoryRoot) }
        agent.memoryQuestions = { asked -> MobileLessons.memoryQuestions(client.workspaceRoot(), asked, memoryText(context), personalMemoryRoot) }
        agent.memoryAnswer = { id, choice -> MobileLessons.answerMemoryQuestion(id, choice, client.workspaceRoot(), personalMemoryRoot) }
        agent.personalMemory = {
            MobilePersonalMemory.text(personalMemoryRoot, if (agent.isNoProjectMode) null else client.workspaceRoot())
        }
        agent.register(AgentTools.runtime(shell, { client.workspaceRoot() }, git, client))
        agent.replaceProjectTools(plugins.reload())
        agent.pluginPrompt = plugins.promptSections.joinToString("\n")
        mcp.connectAll(agent)
        agent.start()
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
            isDarkTheme = isDarkTheme,
            onThemeToggle = onThemeToggle,
        ) {
            preferences.edit().putBoolean("has_seen_intro", true).apply()
            hasSeenIntro = true
        }
    } else {
        WorkspaceShell(
            client, agent, shell, plugins, mcp, loops, git, githubOAuth, chatGPTOAuth,
            legal = legal,
            confirmBeforeExit = confirmBeforeExit,
            selectedLanguage = selectedLanguage,
            onLanguageChange = { language ->
                selectedLanguageCode = language.code
                preferences.setMobileLanguage(language)
            },
            isDarkTheme = isDarkTheme,
            onThemeToggle = onThemeToggle,
            onConfirmBeforeExitChange = { value ->
                preferences.edit().putBoolean("confirm_before_exit", value).apply()
                confirmBeforeExit = value
            },
        )
    }
    // A herness://pair link can be opened by any web page, so the desktop is
    // never contacted until the user confirms the host and the pairing code.
    val pendingPair = client.pendingPair
    if (pendingPair != null) AlertDialog(
        onDismissRequest = { client.cancelPendingPair() },
        title = { Text(stringResource(R.string.mobile_pairing_confirm_title).replace("%@", pendingPair.host)) },
        text = { Text(stringResource(R.string.mobile_pairing_confirm_message).replace("%@", pendingPair.code)) },
        confirmButton = {
            TextButton({ client.confirmPendingPair() }) { Text(stringResource(R.string.common_connect)) }
        },
        dismissButton = {
            TextButton({ client.cancelPendingPair() }) { Text(stringResource(R.string.common_cancel)) }
        },
    )
    }
}

internal val PHONE_AGENT_SYSTEM_PROMPT: String = HerNessPrompt.PHONE
internal const val MOBILE_LANGUAGE_KEY: String = "mobile.language"

private data class IntroSlide(val image: Int, val titleKey: String, val descriptionKey: String)

private val introSlides = listOf(
    IntroSlide(R.drawable.intro_connect, "intro_title_connect", "intro_description_connect"),
    IntroSlide(R.drawable.intro_agent, "intro_title_agent", "intro_description_agent"),
    IntroSlide(R.drawable.intro_ship, "intro_title_ship", "intro_description_ship")
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
    isDarkTheme: Boolean,
    onThemeToggle: () -> Unit,
    onFinish: () -> Unit,
) {
    val context = LocalContext.current
    val layoutDirection = LocalLayoutDirection.current
    val pagerState = rememberPagerState(pageCount = { introSlides.size })
    val scope = rememberCoroutineScope()

    DisposableEffect(context, isDarkTheme) {
        val controller = (context as? Activity)?.window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        controller?.isAppearanceLightStatusBars = !isDarkTheme
        controller?.isAppearanceLightNavigationBars = !isDarkTheme
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
                    .fillMaxWidth()
                    .height(180.dp)
                    .background(
                        Brush.verticalGradient(
                            if (isDarkTheme) listOf(
                                Color.Black.copy(alpha = 0.70f),
                                Color.Black.copy(alpha = 0.30f),
                                Color.Transparent
                            ) else listOf(
                                Color.White.copy(alpha = 0.85f),
                                Color.White.copy(alpha = 0.40f),
                                Color.Transparent
                            )
                        )
                    )
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            if (isDarkTheme) listOf(Color.Transparent, Color.Black.copy(alpha = 0.08f), Color.Black.copy(alpha = 0.92f))
                            else listOf(Color.Transparent, Color.White.copy(alpha = 0.20f), Color.White.copy(alpha = 0.96f))
                        )
                    )
            )
            Column(
                Modifier
                    .fillMaxSize()
                    .safeDrawingPadding()
                    .padding(horizontal = 24.dp, vertical = 16.dp)
            ) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (layoutDirection == LayoutDirection.Rtl) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            if (page < introSlides.lastIndex) {
                                TextButton(
                                    onClick = { scope.launch { pagerState.animateScrollToPage(introSlides.lastIndex) } },
                                    colors = ButtonDefaults.textButtonColors(
                                        contentColor = if (isDarkTheme) Color.White.copy(alpha = 0.92f) else Color.Black.copy(alpha = 0.88f)
                                    )
                                ) {
                                    Text(stringResource(R.string.intro_skip), fontWeight = FontWeight.SemiBold)
                                }
                            }
                            Button(
                                onClick = onThemeToggle,
                                modifier = Modifier.size(36.dp),
                                shape = RoundedCornerShape(18.dp),
                                contentPadding = PaddingValues(0.dp),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = if (isDarkTheme) Color.White.copy(alpha = 0.14f) else Color.Black.copy(alpha = 0.08f),
                                    contentColor = if (isDarkTheme) Color.White else Color(0xFF1C1B1F)
                                )
                            ) {
                                Text(if (isDarkTheme) "☀️" else "🌙", fontSize = 15.sp)
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        CustomLanguagePicker(selectedLanguage, onLanguageChange, darkAppearance = isDarkTheme)
                    } else {
                        CustomLanguagePicker(selectedLanguage, onLanguageChange, darkAppearance = isDarkTheme)
                        Spacer(Modifier.weight(1f))
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button(
                                onClick = onThemeToggle,
                                modifier = Modifier.size(36.dp),
                                shape = RoundedCornerShape(18.dp),
                                contentPadding = PaddingValues(0.dp),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = if (isDarkTheme) Color.White.copy(alpha = 0.14f) else Color.Black.copy(alpha = 0.08f),
                                    contentColor = if (isDarkTheme) Color.White else Color(0xFF1C1B1F)
                                )
                            ) {
                                Text(if (isDarkTheme) "☀️" else "🌙", fontSize = 15.sp)
                            }
                            if (page < introSlides.lastIndex) {
                                TextButton(
                                    onClick = { scope.launch { pagerState.animateScrollToPage(introSlides.lastIndex) } },
                                    colors = ButtonDefaults.textButtonColors(
                                        contentColor = if (isDarkTheme) Color.White.copy(alpha = 0.92f) else Color.Black.copy(alpha = 0.88f)
                                    )
                                ) {
                                    Text(stringResource(R.string.intro_skip), fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                Text(
                    stringResource(resourceId(slide.titleKey)),
                    color = if (isDarkTheme) Color.White else Color.Black,
                    style = MaterialTheme.typography.displaySmall.copy(fontWeight = FontWeight.Bold)
                )
                Text(
                    stringResource(resourceId(slide.descriptionKey)),
                    color = if (isDarkTheme) Color.White.copy(alpha = 0.76f) else Color.Black.copy(alpha = 0.75f),
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
                                .background(
                                    if (index == page) (if (isDarkTheme) Color.White else Color.Black)
                                    else (if (isDarkTheme) Color.White.copy(alpha = 0.3f) else Color.Black.copy(alpha = 0.25f)),
                                    RoundedCornerShape(50)
                                )
                        )
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    @Composable
                    fun BackButton() {
                        Button(
                            onClick = { scope.launch { pagerState.animateScrollToPage(page - 1) } },
                            modifier = Modifier.size(58.dp),
                            shape = RoundedCornerShape(29.dp),
                            contentPadding = PaddingValues(0.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (isDarkTheme) Color.White.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.08f),
                                contentColor = if (isDarkTheme) Color.White else Color.Black
                            ),
                        ) {
                            Text(
                                if (layoutDirection == LayoutDirection.Rtl) "›" else "‹",
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 24.sp
                            )
                        }
                    }

                    @Composable
                    fun PrimaryButton() {
                        Button(
                            onClick = {
                                if (page == introSlides.lastIndex) onFinish() else scope.launch { pagerState.animateScrollToPage(page + 1) }
                            },
                            modifier = Modifier.weight(1f).height(58.dp),
                            shape = RoundedCornerShape(29.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (isDarkTheme) Color.White else Color(0xFF0B0B16),
                                contentColor = if (isDarkTheme) Color(0xFF0B0B16) else Color.White
                            ),
                        ) {
                            Text(
                                stringResource(if (page == introSlides.lastIndex) R.string.intro_start else R.string.intro_continue),
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 17.sp
                            )
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
    "intro_title_connect" -> R.string.intro_title_connect
    "intro_description_connect" -> R.string.intro_description_connect
    "intro_title_agent" -> R.string.intro_title_agent
    "intro_description_agent" -> R.string.intro_description_agent
    "intro_title_ship" -> R.string.intro_title_ship
    "intro_description_ship" -> R.string.intro_description_ship
    else -> error("Unknown intro resource: $key")
}

@Composable
internal fun CustomLanguagePicker(
    selectedLanguage: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    darkAppearance: Boolean,
) {
    var expanded by remember { mutableStateOf(false) }

    Box {
        TextButton(
            onClick = { expanded = !expanded },
            colors = ButtonDefaults.textButtonColors(
                contentColor = if (darkAppearance) Color.White else Color(0xFF1C1B1F)
            ),
        ) {
            Text("${selectedLanguage.flag} ${selectedLanguage.shortCode} ▾", fontWeight = FontWeight.Bold, fontSize = 14.sp)
        }

        if (expanded) {
            Popup(
                alignment = Alignment.TopStart,
                offset = IntOffset(0, 52),
                onDismissRequest = { expanded = false },
                properties = PopupProperties(focusable = true)
            ) {
                Surface(
                    modifier = Modifier
                        .width(188.dp)
                        .heightIn(max = 220.dp),
                    shape = RoundedCornerShape(14.dp),
                    color = if (darkAppearance) Color(0xFF1E1E24) else Color.White,
                    tonalElevation = 6.dp,
                    shadowElevation = 12.dp,
                    border = BorderStroke(
                        1.dp,
                        if (darkAppearance) Color.White.copy(alpha = 0.12f) else Color.Black.copy(alpha = 0.08f)
                    )
                ) {
                    LazyColumn(
                        modifier = Modifier.padding(vertical = 4.dp, horizontal = 4.dp)
                    ) {
                        items(MobileLanguages.supported, key = { it.code }) { language ->
                            val isSelected = selectedLanguage.code == language.code
                            TextButton(
                                onClick = {
                                    onLanguageChange(language)
                                    expanded = false
                                },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                shape = RoundedCornerShape(9.dp),
                                colors = ButtonDefaults.textButtonColors(
                                    containerColor = if (isSelected) {
                                        if (darkAppearance) Color.White.copy(alpha = 0.12f) else Color.Black.copy(alpha = 0.06f)
                                    } else Color.Transparent,
                                    contentColor = if (darkAppearance) Color.White else Color(0xFF1C1B1F)
                                )
                            ) {
                                Row(
                                    Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(language.flag, fontSize = 16.sp)
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        language.nativeName,
                                        fontSize = 13.sp,
                                        fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
                                        modifier = Modifier.weight(1f)
                                    )
                                    if (isSelected) {
                                        Text(
                                            "✓",
                                            color = MaterialTheme.colorScheme.primary,
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 13.sp
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
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
    git: MobileGitClient,
    github: GitHubOAuth,
    chatGPT: ChatGPTOAuth,
    legal: LegalModel,
    selectedLanguage: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    isDarkTheme: Boolean,
    onThemeToggle: () -> Unit,
    confirmBeforeExit: Boolean,
    onConfirmBeforeExitChange: (Boolean) -> Unit,
) {
    var tab by remember { mutableIntStateOf(0) }
    var showingExitConfirmation by remember { mutableStateOf(false) }
    var rememberExit by remember { mutableStateOf(false) }
    var importingFolder by remember { mutableStateOf(false) }
    var relocatingMissingProject by remember { mutableStateOf(false) }
    var folderImportError by remember { mutableStateOf<String?>(null) }
    var showingToolsPanel by remember { mutableStateOf(false) }
    var showingNotifications by remember { mutableStateOf(false) }
    val drawerState = androidx.compose.material3.rememberDrawerState(initialValue = DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val notificationInbox = remember(context) { MobileNotificationInbox.shared(context.applicationContext) }
    var pendingAttentionNotification by remember { mutableStateOf<PendingAttentionNotification?>(null) }
    val attentionNotificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        val pending = pendingAttentionNotification
        if (granted && pending != null) {
            LoopScheduler.notifyAttention(context, pending.id, pending.title, pending.subtitle, pending.detail)
        }
        pendingAttentionNotification = null
    }
    fun postAttentionNotification(notificationID: String, title: String, subtitle: String, detail: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
            && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            val preferences = context.getSharedPreferences("herness.notifications", Context.MODE_PRIVATE)
            val alreadyAsked = preferences.getBoolean("attention_permission_requested", false)
                || preferences.getBoolean("question_permission_requested", false)
            if (alreadyAsked) return
            preferences.edit().putBoolean("attention_permission_requested", true).apply()
            pendingAttentionNotification = PendingAttentionNotification(notificationID, title, subtitle, detail)
            attentionNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            LoopScheduler.notifyAttention(context, notificationID, title, subtitle, detail)
        }
    }
    val personalMemoryRoot = remember(context) { java.io.File(context.filesDir, "herness-memory") }
    val drawerWidth = minOf(androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp.dp * 0.64f, 260.dp)
    var observedRunState by remember { mutableStateOf(agent.running) }
    LaunchedEffect(agent.running) {
        if (observedRunState && !agent.running) {
            val failed = agent.runtimeState == "failed"
            if (failed || agent.runtimeState == "completed") {
                val turn = agent.transcript.lastOrNull { it.role == if (failed) "error" else "assistant" }
                if (turn != null) {
                    val title = context.getString(if (failed) R.string.notifications_operation_failed else R.string.notifications_response_ready)
                    notificationInbox.append(
                        kind = if (failed) "failed" else "completed",
                        title = title,
                        subtitle = client.selectedProject.name,
                        detail = turn.text,
                        conversationId = agent.activeConversationId,
                        projectId = agent.projectId,
                        conversationPath = client.workspaceRoot().absolutePath,
                        isRead = false,
                    )
                    postAttentionNotification(turn.id, title, client.selectedProject.name, turn.text)
                }
            }
        }
        observedRunState = agent.running
    }
    LaunchedEffect(agent.questionRequest?.id) {
        val question = agent.questionRequest ?: return@LaunchedEffect
        val detail = question.askUserQuestions.joinToString(" · ") { it.prompt }.ifBlank { question.question }
        val title = context.getString(R.string.notifications_question)
        val subtitle = client.selectedProject.name
        notificationInbox.append(
            kind = "question",
            title = title,
            subtitle = subtitle,
            detail = detail,
            conversationId = agent.activeConversationId,
            projectId = agent.projectId,
            conversationPath = client.workspaceRoot().absolutePath,
            isRead = false,
        )
        postAttentionNotification(question.id, title, subtitle, detail)
    }
    LaunchedEffect(agent.approvalRequest?.id) {
        val approval = agent.approvalRequest ?: return@LaunchedEffect
        val title = context.getString(R.string.notifications_approval)
        notificationInbox.append(
            kind = "approval",
            title = title,
            subtitle = client.selectedProject.name,
            detail = approval.toolName,
            conversationId = agent.activeConversationId,
            projectId = agent.projectId,
            conversationPath = client.workspaceRoot().absolutePath,
            isRead = tab == 0,
        )
        // The agent tab shows the approval card itself; elsewhere the run would wait unseen.
        if (tab != 0) postAttentionNotification(approval.id, title, client.selectedProject.name, approval.toolName)
    }
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            scope.launch {
                importingFolder = true
                val previousProjectId = client.selectedProjectId
                var importedProject: MobileProject? = null
                var relocationDestination: java.io.File? = null
                try {
                    if (relocatingMissingProject) {
                        val destination = client.newRelocationDestination()
                        relocationDestination = destination
                        ExternalProjectImporter.copySelectedFolder(context, uri, destination)
                        check(client.relocateSelectedProject(destination)) { "The selected folder could not be used as the new project location." }
                        relocatingMissingProject = false
                    } else {
                        val projectName = withContext(Dispatchers.IO) { ExternalProjectImporter.displayName(context, uri) }
                        val project = client.addProject(projectName)
                        importedProject = project
                        agent.selectProject(project.id)
                        ExternalProjectImporter.copySelectedFolder(context, uri, client.workspaceRoot())
                        tab = 1
                    }
                } catch (error: Throwable) {
                    relocationDestination?.let { destination -> withContext(Dispatchers.IO) { destination.deleteRecursively() } }
                    relocatingMissingProject = false
                    importedProject?.let { failedProject ->
                        client.selectProject(previousProjectId)
                        agent.selectProject(previousProjectId)
                        withContext(Dispatchers.IO) {
                            val failedRoot = java.io.File(failedProject.localRoot)
                            failedRoot.deleteRecursively()
                            failedRoot.mkdirs()
                        }
                        client.deleteProject(failedProject.id)
                    }
                    folderImportError = error.localizedMessage ?: "The selected folder could not be imported."
                } finally {
                    importingFolder = false
                }
            }
        }
    }

    fun closeApp() { (context as? Activity)?.finish() }
    fun requestExit() {
        if (confirmBeforeExit) {
            rememberExit = false
            showingExitConfirmation = true
        } else {
            closeApp()
        }
    }

    BackHandler(enabled = showingToolsPanel) { showingToolsPanel = false }
    BackHandler(enabled = tab != 0) { tab = 0 }
    BackHandler(enabled = tab == 0 && !showingToolsPanel && !drawerState.isOpen) { requestExit() }
    LaunchedEffect(client.selectedProjectId) {
        shell.resetForProject()
        agent.register(WebTools.specs())
        agent.register(AgentTools.workspace({ client.workspaceRoot() }, { personalMemoryRoot }))
        agent.learnedRules = { MobileLessons.rulesText(client.workspaceRoot(), userRoot = personalMemoryRoot) }
        agent.memoryQuestions = { asked -> MobileLessons.memoryQuestions(client.workspaceRoot(), asked, memoryText(context), personalMemoryRoot) }
        agent.memoryAnswer = { id, choice -> MobileLessons.answerMemoryQuestion(id, choice, client.workspaceRoot(), personalMemoryRoot) }
        agent.register(AgentTools.runtime(shell, { client.workspaceRoot() }, git, client))
        agent.replaceProjectTools(plugins.reload())
        agent.pluginPrompt = plugins.promptSections.joinToString("\n")
        mcp.connectAll(agent)
    }
    LaunchedEffect(client.selectedProjectId) {
        while (true) {
            client.refreshProjectAvailability()
            kotlinx.coroutines.delay(1_000)
        }
    }
    val foldingFeatures = rememberWindowFoldingFeatures()
    val isFoldableDevice = remember(context) {
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_SENSOR_HINGE_ANGLE)
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val foldFeature = foldingFeatures.firstOrNull()
        val isSeparatingTabletop = foldFeature?.let {
            it.isSeparating && it.orientation == FoldingFeature.Orientation.HORIZONTAL
        } == true
        val shouldUseFoldableWorkspace = isSeparatingTabletop ||
            (maxWidth >= 600.dp && (foldFeature != null || isFoldableDevice))
        if (shouldUseFoldableWorkspace) {
            FoldableWorkspaceLayout(
                foldingFeature = foldFeature,
                sidebar = { paneModifier ->
                    FoldableSidebar(
                        modifier = paneModifier,
                        client = client,
                        agent = agent,
                        loops = loops,
                        notificationInbox = notificationInbox,
                        importingFolder = importingFolder,
                        selectedTab = tab,
                        onTabSelected = { tab = it; showingToolsPanel = false },
                        onNewConversation = { agent.reset(); tab = 0 },
                        onConversationSelected = { id -> if (agent.openConversation(id)) tab = 0 },
                        onProjectSelected = { id ->
                            if (!agent.running && loops.running == null && client.selectProject(id)) {
                                agent.selectProject(id)
                                tab = 0
                            }
                        },
                        onNotificationsClick = { showingNotifications = true },
                    )
                },
                bottomSidebar = { paneModifier ->
                    FoldableBottomSidebar(
                        modifier = paneModifier,
                        client = client,
                        agent = agent,
                        loops = loops,
                        notificationInbox = notificationInbox,
                        importingFolder = importingFolder,
                        selectedTab = tab,
                        onTabSelected = { tab = it; showingToolsPanel = false },
                        onNewConversation = { agent.reset(); tab = 0 },
                        onConversationSelected = { id -> if (agent.openConversation(id)) tab = 0 },
                        onProjectSelected = { id ->
                            if (!agent.running && loops.running == null && client.selectProject(id)) {
                                agent.selectProject(id)
                                tab = 0
                            }
                        },
                        onNotificationsClick = { showingNotifications = true },
                    )
                },
                content = { paneModifier ->
                    FoldableWorkspaceContent(
                        modifier = paneModifier,
                        tab = tab,
                        client = client,
                        agent = agent,
                        shell = shell,
                        plugins = plugins,
                        mcp = mcp,
                        loops = loops,
                        personalMemoryRoot = personalMemoryRoot,
                        github = github,
                        chatGPT = chatGPT,
                        legal = legal,
                        selectedLanguage = selectedLanguage,
                        onLanguageChange = onLanguageChange,
                        isDarkTheme = isDarkTheme,
                        onThemeToggle = onThemeToggle,
                        confirmBeforeExit = confirmBeforeExit,
                        onConfirmBeforeExitChange = onConfirmBeforeExitChange,
                        onExit = ::requestExit,
                        onEnsureProjectLocation = {
                            if (!importingFolder && client.selectedProjectLocationAvailable.not()) {
                                relocatingMissingProject = true
                                folderPicker.launch(null)
                            }
                        },
                        onImportFolder = { folderPicker.launch(null) },
                        isImporting = importingFolder,
                        onReturnToAgent = { tab = 0 },
                    )
                },
            )
        } else {
    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet(modifier = Modifier.width(drawerWidth).fillMaxHeight()) {
                FoldableSidebar(
                    modifier = Modifier.fillMaxSize(),
                    client = client,
                    agent = agent,
                    loops = loops,
                        notificationInbox = notificationInbox,
                    importingFolder = importingFolder,
                    selectedTab = tab,
                    onTabSelected = {
                        tab = it
                        showingToolsPanel = false
                        scope.launch { drawerState.close() }
                    },
                    onNewConversation = {
                        agent.reset()
                        tab = 0
                        scope.launch { drawerState.close() }
                    },
                    onConversationSelected = { id ->
                        if (agent.openConversation(id)) {
                            tab = 0
                            scope.launch { drawerState.close() }
                        }
                    },
                    onProjectSelected = { id ->
                        if (!agent.running && loops.running == null && !importingFolder && client.selectProject(id)) {
                            agent.selectProject(id)
                            tab = 0
                            scope.launch { drawerState.close() }
                        }
                    },
                    onNotificationsClick = {
                        showingNotifications = true
                        scope.launch { drawerState.close() }
                    },
                    onDismiss = { scope.launch { drawerState.close() } },
                )
            }
        }
    ) {
        Scaffold(
            containerColor = if (tab == 4) {
                if (isDarkTheme) Color.Black else Color.White
            } else MaterialTheme.colorScheme.background,
            contentWindowInsets = androidx.compose.material3.ScaffoldDefaults.contentWindowInsets,
        ) { padding ->
            Box(Modifier.padding(padding).fillMaxSize()) {
                Column(Modifier.fillMaxSize()) {
                    if (tab == 0) {
                        ProjectScopeBar(
                            client,
                            agent,
                            loops,
                            notificationInbox = notificationInbox,
                            importLocked = importingFolder,
                            onMenuClick = { scope.launch { drawerState.open() } },
                            onNotificationsClick = { showingNotifications = true },
                            onToolsClick = { showingToolsPanel = true },
                        )
                    } else {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconButton(onClick = { tab = 0 }) {
                                Icon(Icons.Filled.ArrowBack, contentDescription = stringResource(R.string.intro_back))
                            }
                            if (tab != 4) {
                                Text(
                                    when (tab) {
                                        1 -> stringResource(R.string.conversation_files)
                                        2 -> stringResource(R.string.mobile_nav_terminal)
                                        3 -> stringResource(R.string.mobile_nav_preview)
                                        5 -> stringResource(R.string.rail_tasks)
                                        6 -> stringResource(R.string.rail_memory)
                                        7 -> stringResource(R.string.rail_media)
                                        8 -> stringResource(R.string.rail_bots)
                                        9 -> stringResource(R.string.rail_marketplace)
                                        else -> stringResource(R.string.mobile_nav_settings)
                                    },
                                    style = MaterialTheme.typography.titleMedium,
                                )
                            }
                        }
                    }
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        when (tab) {
                            0 -> AgentTab(
                                agent = agent,
                                client = client,
                                onLocateMissing = {
                                    if (!importingFolder && !client.selectedProjectLocationAvailable) {
                                        relocatingMissingProject = true
                                        folderPicker.launch(null)
                                    }
                                },
                                canSwitchProject = !agent.running && loops.running == null && !importingFolder,
                                onProjectSelected = { id ->
                                    if (!agent.running && loops.running == null && !importingFolder && (client.selectedProjectId == id || client.selectProject(id))) {
                                        agent.selectProject(id)
                                    }
                                },
                            )
                            1 -> FilesScreen(
                                client.selectedProjectId,
                                { client.workspaceRoot() },
                                onImportFolder = { folderPicker.launch(null) },
                                isImporting = importingFolder,
                            )
                            2 -> TerminalTab(shell, client)
                            3 -> PreviewScreen(client)
                            5 -> TasksScreen(loops)
                            6 -> MemoryScreen(client, personalMemoryRoot)
                            7 -> MobileMediaStudioScreen(client)
                            8 -> MobileBotsScreen(client, agent) { tab = 0 }
                            9 -> MobileMarketplaceScreen(client, agent) { tab = 0 }
                            else -> SettingsScreen(client, agent, plugins, mcp, loops, github, chatGPT, legal, selectedLanguage, onLanguageChange, isDarkTheme, onThemeToggle, confirmBeforeExit, onConfirmBeforeExitChange, ::requestExit)
                        }
                    }
                }
                WorkspaceToolsDrawer(
                    visible = showingToolsPanel,
                    selectedTab = tab,
                    projectName = client.selectedProject.name,
                    darkAppearance = isDarkTheme,
                    onDismiss = { showingToolsPanel = false },
                    onSelect = { selected ->
                        tab = selected
                        showingToolsPanel = false
                    },
                )
            }
        }
    }
        }
    }
    if (folderImportError != null) AlertDialog(
        onDismissRequest = { folderImportError = null },
        title = { Text(stringResource(R.string.conversation_files)) },
        text = { Text(folderImportError.orEmpty()) },
        confirmButton = { TextButton({ folderImportError = null }) { Text(stringResource(R.string.app_ok)) } },
    )
    if (showingNotifications) MobileNotificationsDialog(
        inbox = notificationInbox,
        onDismiss = { showingNotifications = false },
        onSelect = { item ->
            val projectId = item.projectId
            if (projectId == MobileAgent.NO_PROJECT_ID && agent.projectId != MobileAgent.NO_PROJECT_ID) {
                if (agent.running || loops.running != null) return@MobileNotificationsDialog
                agent.selectNoProject()
            } else if (!projectId.isNullOrBlank() && projectId != MobileAgent.NO_PROJECT_ID && projectId != client.selectedProjectId) {
                if (agent.running || loops.running != null || !client.selectProject(projectId)) return@MobileNotificationsDialog
                agent.selectProject(projectId)
            }
            if (!item.conversationId.isNullOrBlank() && !agent.openConversation(item.conversationId)) return@MobileNotificationsDialog
            notificationInbox.markRead(item.id)
            tab = 0
            showingNotifications = false
        },
    )
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
private fun rememberWindowFoldingFeatures(): List<FoldingFeature> {
    val activity = LocalContext.current.findActivity()
    val features by produceState(initialValue = emptyList<FoldingFeature>(), activity) {
        if (activity == null) return@produceState
        WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity).collect { layoutInfo ->
            value = layoutInfo.displayFeatures.filterIsInstance<FoldingFeature>()
        }
    }
    return features
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

@Composable
private fun FoldableWorkspaceLayout(
    foldingFeature: FoldingFeature?,
    sidebar: @Composable (Modifier) -> Unit,
    bottomSidebar: @Composable (Modifier) -> Unit,
    content: @Composable (Modifier) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val isBookPosture = foldingFeature?.let {
            it.isSeparating && it.orientation == FoldingFeature.Orientation.VERTICAL
        } == true
        val isTabletopPosture = foldingFeature?.let {
            it.isSeparating && it.orientation == FoldingFeature.Orientation.HORIZONTAL
        } == true

        if (isTabletopPosture) {
            val tabletopFeature = requireNotNull(foldingFeature)
            val foldStart = with(density) { tabletopFeature.bounds.top.toDp() }
            val foldEnd = with(density) { tabletopFeature.bounds.bottom.toDp() }
            val rawHingeHeight = (foldEnd - foldStart).coerceAtLeast(0.dp)
            val hingeHeight = rawHingeHeight.coerceAtLeast(12.dp).coerceAtMost(maxHeight)
            val addedClearance = hingeHeight - rawHingeHeight
            val topHeight = (foldStart - addedClearance / 2).coerceAtLeast(0.dp)
                .coerceAtMost((maxHeight - hingeHeight).coerceAtLeast(0.dp))
            val bottomHeight = (maxHeight - topHeight - hingeHeight).coerceAtLeast(0.dp)

            Column(Modifier.fillMaxSize()) {
                Box(Modifier.fillMaxWidth().height(topHeight).safeDrawingPadding()) {
                    content(Modifier.fillMaxSize())
                }
                Box(Modifier.fillMaxWidth().height(hingeHeight).background(MaterialTheme.colorScheme.surfaceVariant))
                Box(Modifier.fillMaxWidth().height(bottomHeight).safeDrawingPadding()) {
                    bottomSidebar(Modifier.fillMaxSize())
                }
            }
        } else {
            val foldStart = if (isBookPosture) with(density) { requireNotNull(foldingFeature).bounds.left.toDp() } else 0.dp
            val foldEnd = if (isBookPosture) with(density) { requireNotNull(foldingFeature).bounds.right.toDp() } else foldStart
            val rawHingeWidth = (foldEnd - foldStart).coerceAtLeast(0.dp)
            val hingeWidth = when {
                isBookPosture -> rawHingeWidth.coerceAtLeast(12.dp)
                foldingFeature != null -> 1.dp
                else -> 0.dp
            }
            val addedClearance = if (isBookPosture) hingeWidth - rawHingeWidth else 0.dp
            val sidebarWidth = if (isBookPosture) {
                (foldStart - addedClearance / 2).coerceAtLeast(0.dp)
            } else {
                (maxWidth * 0.4f).coerceIn(240.dp, 320.dp)
            }

            Row(Modifier.fillMaxSize()) {
                sidebar(Modifier.width(sidebarWidth).fillMaxHeight().safeDrawingPadding())
                Box(
                    Modifier.width(hingeWidth).fillMaxHeight().background(
                        if (isBookPosture) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.outlineVariant,
                    ),
                )
                content(Modifier.weight(1f).fillMaxHeight().safeDrawingPadding())
            }
        }
    }
}

private data class FoldableNavigationItem(val tab: Int, val title: String, val icon: ImageVector)

@Composable
private fun foldableNavigationItems() = listOf(
    FoldableNavigationItem(1, stringResource(R.string.conversation_files), Icons.Filled.Folder),
    FoldableNavigationItem(2, stringResource(R.string.mobile_nav_terminal), Icons.Filled.Terminal),
    FoldableNavigationItem(3, stringResource(R.string.mobile_nav_preview), Icons.Filled.Language),
    FoldableNavigationItem(5, stringResource(R.string.rail_tasks), Icons.Filled.Schedule),
    FoldableNavigationItem(6, stringResource(R.string.rail_memory), Icons.Filled.Psychology),
    FoldableNavigationItem(7, stringResource(R.string.rail_media), Icons.Filled.AutoAwesome),
    FoldableNavigationItem(8, stringResource(R.string.rail_bots), Icons.Filled.Psychology),
    FoldableNavigationItem(9, stringResource(R.string.rail_marketplace), Icons.Filled.Folder),
    FoldableNavigationItem(4, stringResource(R.string.mobile_nav_settings), Icons.Filled.Settings),
)

@Composable
private fun FoldableProjectPicker(
    modifier: Modifier,
    client: RemoteClient,
    enabled: Boolean,
    onProjectSelected: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        Surface(
            modifier = Modifier.fillMaxWidth().clickable(enabled = enabled) { expanded = true },
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.Folder, contentDescription = null, modifier = Modifier.size(18.dp))
                Text(client.selectedProject.name, Modifier.weight(1f), maxLines = 1, style = MaterialTheme.typography.titleSmall)
                Icon(Icons.Filled.ExpandMore, contentDescription = null, modifier = Modifier.size(20.dp))
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            client.projects.forEach { project ->
                DropdownMenuItem(
                    text = { Text(project.name, maxLines = 1) },
                    onClick = {
                        expanded = false
                        if (project.id != client.selectedProjectId) onProjectSelected(project.id)
                    },
                )
            }
        }
    }
}

private data class MobileSidebarProjectRow(val project: MobileProject, val groupTitle: String?)

@Composable
private fun FoldableSidebar(
    modifier: Modifier,
    client: RemoteClient,
    agent: MobileAgent,
    loops: LoopScheduler,
    notificationInbox: MobileNotificationInbox,
    importingFolder: Boolean,
    selectedTab: Int,
    onTabSelected: (Int) -> Unit,
    onNewConversation: () -> Unit,
    onConversationSelected: (String) -> Unit,
    onProjectSelected: (String) -> Unit,
    onNotificationsClick: () -> Unit,
    onDismiss: (() -> Unit)? = null,
) {
    var conversations by remember(client.selectedProjectId) { mutableStateOf(emptyList<StoredMobileConversation>()) }
    var expandedProjectId by remember(client.selectedProjectId) { mutableStateOf<String?>(client.selectedProjectId) }
    var isAddingProject by remember { mutableStateOf(false) }
    var newProjectName by remember { mutableStateOf("") }
    var organizationMenuExpanded by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val projectPreferences = remember(context) { context.getSharedPreferences("herness.preferences", Context.MODE_PRIVATE) }
    var projectGrouping by remember(projectPreferences) {
        mutableStateOf(projectPreferences.getString("mobile.sidebar.projectGrouping", "source") ?: "source")
    }
    var projectSort by remember(projectPreferences) {
        mutableStateOf(projectPreferences.getString("mobile.sidebar.projectSort", "default") ?: "default")
    }
    val projectGroups = remember(client.projects, projectGrouping, projectSort) {
        organizeMobileProjects(client.projects, groupBySource = projectGrouping == "source", sortByName = projectSort == "name")
    }
    val localWorkspaceLabel = stringResource(R.string.mobile_workspace_local)
    val projectRows = projectGroups.flatMap { group ->
        group.projects.mapIndexed { index, project ->
            val title = if (projectGrouping != "source" || index > 0) null else when (group.key) {
                "local" -> localWorkspaceLabel
                "github" -> "GitHub"
                else -> "Desktop"
            }
            MobileSidebarProjectRow(project, title)
        }
    }
    val navItems = foldableNavigationItems()
    val untitledConversation = stringResource(R.string.mobile_agent_new_conversation)
    val notificationsLabel = if (notificationInbox.unreadCount > 0) {
        stringResource(R.string.notifications_unread_count, notificationInbox.unreadCount)
    } else stringResource(R.string.notifications_title)
    LaunchedEffect(client.selectedProjectId, agent.projectId, agent.transcript.size, agent.running, agent.runtimeState, agent.activeConversationId, agent.conversationListRevision) {
        conversations = withContext(Dispatchers.IO) { agent.projectConversations() }
    }

    Column(
        modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).padding(horizontal = 14.dp).padding(bottom = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("HerNess", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onNotificationsClick) {
                Text(
                    if (notificationInbox.unreadCount > 0) "🔔 ${notificationInbox.unreadCount}" else "🔔",
                    modifier = Modifier.semantics { contentDescription = notificationsLabel },
                )
            }
            if (onDismiss != null) {
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.mobile_agent_close))
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(
            onClick = onNewConversation,
            enabled = !agent.running && loops.running == null && !importingFolder && client.selectedProjectLocationAvailable,
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.mobile_agent_new_conversation), maxLines = 1)
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 4.dp, top = 12.dp, bottom = 2.dp)) {
            Text("Projects", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { organizationMenuExpanded = true }) {
                Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.sidebar_group_by))
            }
            DropdownMenu(expanded = organizationMenuExpanded, onDismissRequest = { organizationMenuExpanded = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sidebar_group_by), style = MaterialTheme.typography.labelLarge) },
                    onClick = {},
                    enabled = false,
                )
                DropdownMenuItem(
                    text = { Text((if (projectGrouping == "source") "✓ " else "") + stringResource(R.string.market_field_source)) },
                    onClick = {
                        projectGrouping = "source"
                        projectPreferences.edit().putString("mobile.sidebar.projectGrouping", projectGrouping).apply()
                    },
                )
                DropdownMenuItem(
                    text = { Text((if (projectGrouping == "none") "✓ " else "") + stringResource(R.string.sidebar_project_grouping_none)) },
                    onClick = {
                        projectGrouping = "none"
                        projectPreferences.edit().putString("mobile.sidebar.projectGrouping", projectGrouping).apply()
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sidebar_sort_projects_by), style = MaterialTheme.typography.labelLarge) },
                    onClick = {},
                    enabled = false,
                )
                DropdownMenuItem(
                    text = { Text((if (projectSort == "default") "✓ " else "") + stringResource(R.string.sidebar_project_sort_default)) },
                    onClick = {
                        projectSort = "default"
                        projectPreferences.edit().putString("mobile.sidebar.projectSort", projectSort).apply()
                    },
                )
                DropdownMenuItem(
                    text = { Text((if (projectSort == "name") "✓ " else "") + stringResource(R.string.studio_home_sort_name)) },
                    onClick = {
                        projectSort = "name"
                        projectPreferences.edit().putString("mobile.sidebar.projectSort", projectSort).apply()
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.model_picker_reset)) },
                    onClick = {
                        projectGrouping = "source"
                        projectSort = "default"
                        projectPreferences.edit()
                            .putString("mobile.sidebar.projectGrouping", projectGrouping)
                            .putString("mobile.sidebar.projectSort", projectSort)
                            .apply()
                        organizationMenuExpanded = false
                    },
                )
            }
            IconButton(
                onClick = { isAddingProject = !isAddingProject },
                enabled = !agent.running && loops.running == null && !importingFolder,
            ) {
                Icon(
                    if (isAddingProject) Icons.Filled.Close else Icons.Filled.Add,
                    contentDescription = if (isAddingProject) stringResource(R.string.mobile_agent_close) else "Add project",
                )
            }
        }

        if (isAddingProject) {
            OutlinedTextField(
                value = newProjectName,
                onValueChange = { newProjectName = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                placeholder = { Text("New project") },
                trailingIcon = {
                    IconButton(
                    onClick = {
                        val project = client.addProject(newProjectName.trim())
                        newProjectName = ""
                        agent.selectProject(project.id)
                        expandedProjectId = project.id
                        onTabSelected(0)
                        onDismiss?.invoke()
                    },
                    enabled = newProjectName.isNotBlank() && !agent.running && loops.running == null && !importingFolder,
                    ) {
                        Icon(Icons.Filled.CheckCircle, contentDescription = "Add project")
                    }
                },
            )
            Spacer(Modifier.height(4.dp))
        }

        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            items(projectRows, key = { it.project.id }) { row ->
                val project = row.project
                val isSelected = project.id == client.selectedProjectId
                val isExpanded = expandedProjectId == project.id
                Column {
                    row.groupTitle?.let { title ->
                        Text(
                            title,
                            modifier = Modifier.padding(start = 10.dp, top = 8.dp, bottom = 2.dp),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Surface(
                        modifier = Modifier.fillMaxWidth().clickable(
                            enabled = !agent.running && loops.running == null && !importingFolder,
                            onClick = {
                                if (isSelected) {
                                    expandedProjectId = if (isExpanded) null else project.id
                                } else {
                                    expandedProjectId = project.id
                                    onProjectSelected(project.id)
                                }
                            },
                        ),
                        shape = RoundedCornerShape(9.dp),
                        color = if (isSelected) MaterialTheme.colorScheme.primaryContainer else Color.Transparent,
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Filled.Folder, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text(
                                project.name,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (java.io.File(project.localRoot).isDirectory) 1f else 0.55f),
                            )
                            Icon(Icons.Filled.ExpandMore, contentDescription = null, modifier = Modifier.size(18.dp))
                        }
                    }
                    if (isSelected && isExpanded) {
                        Text(
                            if (agent.isNoProjectMode) stringResource(R.string.mobile_agent_no_project) else project.name,
                            modifier = Modifier.padding(start = 28.dp, top = 8.dp, bottom = 3.dp),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (conversations.isEmpty()) {
                            Text(
                                stringResource(R.string.sidebar_no_chats),
                                modifier = Modifier.padding(start = 28.dp, top = 3.dp, bottom = 8.dp),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        } else {
                            conversations.take(7).forEach { conversation ->
                                val selected = conversation.id == agent.activeConversationId
                                Surface(
                                    modifier = Modifier.fillMaxWidth().padding(start = 14.dp).clickable(
                                        enabled = !agent.running,
                                        onClick = { onConversationSelected(conversation.id) },
                                    ),
                                    shape = RoundedCornerShape(9.dp),
                                    color = if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent,
                                ) {
                                    Text(
                                        conversation.title.ifBlank { untitledConversation },
                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                                        maxLines = 2,
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        HorizontalDivider(Modifier.padding(vertical = 8.dp))
        navItems.forEach { item ->
            NavigationDrawerItem(
                label = { Text(item.title, maxLines = 1) },
                selected = selectedTab == item.tab,
                onClick = {
                    onTabSelected(item.tab)
                    onDismiss?.invoke()
                },
                icon = { Icon(item.icon, contentDescription = null) },
                modifier = Modifier.padding(vertical = 1.dp),
            )
        }
    }
}

@Composable
private fun FoldableBottomSidebar(
    modifier: Modifier,
    client: RemoteClient,
    agent: MobileAgent,
    loops: LoopScheduler,
    notificationInbox: MobileNotificationInbox,
    importingFolder: Boolean,
    selectedTab: Int,
    onTabSelected: (Int) -> Unit,
    onNewConversation: () -> Unit,
    onConversationSelected: (String) -> Unit,
    onProjectSelected: (String) -> Unit,
    onNotificationsClick: () -> Unit,
) {
    var conversations by remember(client.selectedProjectId) { mutableStateOf(emptyList<StoredMobileConversation>()) }
    val navItems = foldableNavigationItems()
    val untitledConversation = stringResource(R.string.mobile_agent_new_conversation)
    val notificationsLabel = if (notificationInbox.unreadCount > 0) {
        stringResource(R.string.notifications_unread_count, notificationInbox.unreadCount)
    } else stringResource(R.string.notifications_title)
    LaunchedEffect(client.selectedProjectId, agent.projectId, agent.transcript.size, agent.running, agent.runtimeState, agent.activeConversationId, agent.conversationListRevision) {
        conversations = withContext(Dispatchers.IO) { agent.projectConversations() }
    }

    Column(
        modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FoldableProjectPicker(
                modifier = Modifier.weight(1f),
                client = client,
                enabled = !agent.running && loops.running == null && !importingFolder,
                onProjectSelected = onProjectSelected,
            )
            IconButton(onClick = onNotificationsClick) {
                Text(
                    if (notificationInbox.unreadCount > 0) "🔔 ${notificationInbox.unreadCount}" else "🔔",
                    modifier = Modifier.semantics { contentDescription = notificationsLabel },
                )
            }
            IconButton(onClick = onNewConversation, enabled = !agent.running && !importingFolder) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.mobile_agent_new_conversation))
            }
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
            navItems.forEach { item ->
                NavigationDrawerItem(
                    label = { Text(item.title, maxLines = 1) },
                    selected = selectedTab == item.tab,
                    onClick = { onTabSelected(item.tab) },
                    icon = { Icon(item.icon, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    modifier = Modifier.width(132.dp).padding(horizontal = 2.dp),
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (agent.isNoProjectMode) stringResource(R.string.mobile_agent_no_project) else client.selectedProject.name,
                style = MaterialTheme.typography.titleSmall,
            )
            if (conversations.isEmpty()) {
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.sidebar_no_chats), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (conversations.isNotEmpty()) {
            LazyRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(conversations, key = { it.id }) { conversation ->
                    val selected = conversation.id == agent.activeConversationId
                    Surface(
                        modifier = Modifier.width(210.dp).clickable(
                            enabled = !agent.running,
                            onClick = { onConversationSelected(conversation.id) },
                        ),
                        shape = RoundedCornerShape(10.dp),
                        color = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                    ) {
                        Text(
                            conversation.title.ifBlank { untitledConversation },
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                            maxLines = 2,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FoldableWorkspaceContent(
    modifier: Modifier,
    tab: Int,
    client: RemoteClient,
    agent: MobileAgent,
    shell: LocalShell,
    plugins: Plugins,
    mcp: McpRegistry,
    loops: LoopScheduler,
    personalMemoryRoot: java.io.File,
    github: GitHubOAuth,
    chatGPT: ChatGPTOAuth,
    legal: LegalModel,
    selectedLanguage: MobileLanguage,
    onLanguageChange: (MobileLanguage) -> Unit,
    isDarkTheme: Boolean,
    onThemeToggle: () -> Unit,
    confirmBeforeExit: Boolean,
    onConfirmBeforeExitChange: (Boolean) -> Unit,
    onExit: () -> Unit,
    onEnsureProjectLocation: () -> Unit,
    onImportFolder: () -> Unit,
    isImporting: Boolean,
    onReturnToAgent: () -> Unit,
) {
    Scaffold(
        modifier = modifier,
        containerColor = if (tab == 4) {
            if (isDarkTheme) Color.Black else Color.White
        } else MaterialTheme.colorScheme.background,
        contentWindowInsets = androidx.compose.material3.ScaffoldDefaults.contentWindowInsets,
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (tab == 0) {
                val title = agent.transcript.firstOrNull { it.role == "user" }
                    ?.text?.lineSequence()?.firstOrNull()?.take(100)
                    .orEmpty().ifBlank { stringResource(R.string.mobile_nav_agent) }
                Text(
                    title,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 10.dp),
                    maxLines = 1,
                    style = MaterialTheme.typography.titleMedium,
                )
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when (tab) {
                    0 -> AgentTab(
                        agent = agent,
                        client = client,
                        onLocateMissing = onEnsureProjectLocation,
                        canSwitchProject = !agent.running && loops.running == null && !isImporting,
                        onProjectSelected = { id ->
                            if (!agent.running && loops.running == null && (client.selectedProjectId == id || client.selectProject(id))) agent.selectProject(id)
                        },
                    )
                    1 -> FilesScreen(client.selectedProjectId, { client.workspaceRoot() }, onImportFolder, isImporting)
                    2 -> TerminalTab(shell, client)
                    3 -> PreviewScreen(client)
                    5 -> TasksScreen(loops)
                    6 -> MemoryScreen(client, personalMemoryRoot)
                    7 -> MobileMediaStudioScreen(client)
                    8 -> MobileBotsScreen(client, agent, onReturnToAgent)
                    9 -> MobileMarketplaceScreen(client, agent, onReturnToAgent)
                    else -> SettingsScreen(
                        client, agent, plugins, mcp, loops, github, chatGPT, legal,
                        selectedLanguage, onLanguageChange, isDarkTheme, onThemeToggle,
                        confirmBeforeExit, onConfirmBeforeExitChange, onExit,
                    )
                }
            }
        }
    }
}

@Composable
private fun WorkspaceToolsDrawer(
    visible: Boolean,
    selectedTab: Int,
    projectName: String,
    darkAppearance: Boolean,
    onDismiss: () -> Unit,
    onSelect: (Int) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize().zIndex(5f)) {
        AnimatedVisibility(
            visible = visible,
            modifier = Modifier.matchParentSize(),
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            Box(
                Modifier.fillMaxSize()
                    .background(Color.Black.copy(alpha = if (darkAppearance) 0.58f else 0.32f))
                    .clickable(onClick = onDismiss)
            )
        }
        AnimatedVisibility(
            visible = visible,
            modifier = Modifier.align(Alignment.TopEnd),
            enter = slideInHorizontally(initialOffsetX = { it }) + fadeIn(),
            exit = slideOutHorizontally(targetOffsetX = { it }) + fadeOut(),
        ) {
            Surface(
                modifier = Modifier.padding(top = 8.dp, end = 8.dp)
                    .width(minOf(maxWidth * 0.78f, 300.dp))
                    .wrapContentHeight(),
                shape = RoundedCornerShape(22.dp),
                color = if (darkAppearance) Color.Black else Color.White,
                tonalElevation = 0.dp,
                shadowElevation = 18.dp,
            ) {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(projectName, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, maxLines = 1)
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.intro_back))
                        }
                    }
                    HorizontalDivider(Modifier.padding(bottom = 12.dp))
                    NavigationDrawerItem(
                        label = { Text(stringResource(R.string.conversation_files)) },
                        selected = selectedTab == 1,
                        onClick = { onSelect(1) },
                        icon = { Icon(Icons.Filled.Folder, contentDescription = null) },
                    )
                    NavigationDrawerItem(
                        label = { Text(stringResource(R.string.mobile_nav_terminal)) },
                        selected = selectedTab == 2,
                        onClick = { onSelect(2) },
                        icon = { Icon(Icons.Filled.Terminal, contentDescription = null) },
                    )
                    NavigationDrawerItem(
                        label = { Text(stringResource(R.string.mobile_nav_preview)) },
                        selected = selectedTab == 3,
                        onClick = { onSelect(3) },
                        icon = { Icon(Icons.Filled.Language, contentDescription = null) },
                    )
                    NavigationDrawerItem(
                        label = { Text(stringResource(R.string.rail_tasks)) },
                        selected = selectedTab == 5,
                        onClick = { onSelect(5) },
                        icon = { Icon(Icons.Filled.Schedule, contentDescription = null) },
                    )
                    NavigationDrawerItem(
                        label = { Text(stringResource(R.string.rail_memory)) },
                        selected = selectedTab == 6,
                        onClick = { onSelect(6) },
                        icon = { Icon(Icons.Filled.Psychology, contentDescription = null) },
                    )
                }
            }
        }
    }
}

@Composable
private fun ProjectScopeBar(
    client: RemoteClient,
    agent: MobileAgent,
    loops: LoopScheduler,
    notificationInbox: MobileNotificationInbox,
    importLocked: Boolean = false,
    onMenuClick: () -> Unit,
    onNotificationsClick: () -> Unit,
    onToolsClick: () -> Unit,
) {
    var newProjectName by remember { mutableStateOf("") }
    var renameName by remember(client.selectedProjectId) { mutableStateOf(client.selectedProject.name) }
    val notificationsLabel = if (notificationInbox.unreadCount > 0) {
        stringResource(R.string.notifications_unread_count, notificationInbox.unreadCount)
    } else stringResource(R.string.notifications_title)
    val projectSwitchLocked = agent.running || loops.running != null || importLocked

    fun select(id: String) {
        if (projectSwitchLocked || id == client.selectedProjectId) return
        if (client.selectProject(id)) agent.selectProject(id)
    }

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onMenuClick) {
                Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.mobile_nav_menu))
            }
            Text("Projects", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onNotificationsClick) {
                Text(
                    if (notificationInbox.unreadCount > 0) "🔔 ${notificationInbox.unreadCount}" else "🔔",
                    modifier = Modifier.semantics { contentDescription = notificationsLabel },
                )
            }
            IconButton(onClick = onToolsClick) {
                Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.mobile_nav_menu))
            }
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            client.projects.forEach { project ->
                TextButton(
                    onClick = { select(project.id) },
                enabled = !projectSwitchLocked,
                    colors = ButtonDefaults.textButtonColors(
                        containerColor = if (project.id == client.selectedProjectId) MaterialTheme.colorScheme.primaryContainer else Color.Transparent,
                    ),
                ) {
                    val available = java.io.File(project.localRoot).isDirectory
                    Text(
                        if (project.id == client.selectedProjectId) "✓ ${project.name}" else project.name,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (available) 1f else 0.46f),
                    )
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                newProjectName,
                { newProjectName = it },
                Modifier.weight(1f),
                singleLine = true,
                label = { Text("New project") },
            )
            Button(
                onClick = {
                    val project = client.addProject(newProjectName)
                    newProjectName = ""
                    agent.selectProject(project.id)
                },
                enabled = newProjectName.isNotBlank() && !projectSwitchLocked,
            ) { Text("Add") }
        }
        if (client.projects.size > 1) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(renameName, { renameName = it }, Modifier.weight(1f), singleLine = true, label = { Text("Selected project") })
                TextButton(onClick = { client.renameProject(client.selectedProjectId, renameName) }, enabled = renameName.isNotBlank() && !projectSwitchLocked) { Text("Rename") }
                TextButton(
                    onClick = {
                        val deleted = client.selectedProjectId
                        client.projects.firstOrNull { it.id != deleted }?.let { next ->
                            select(next.id)
                            client.deleteProject(deleted)
                        }
                    },
                    enabled = !projectSwitchLocked,
                ) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            }
        }
        if (client.paired && client.remoteProjects.isNotEmpty()) {
            Text("Desktop projects", style = MaterialTheme.typography.labelLarge)
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    client.remoteProjects.forEach { project ->
                        TextButton(
                        onClick = { if (!projectSwitchLocked) client.selectRemoteProject(project.id) },
                        enabled = !projectSwitchLocked,
                        colors = ButtonDefaults.textButtonColors(
                            containerColor = if (project.id == client.remoteSelectedProjectId) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent,
                        ),
                    ) { Text(if (project.id == client.remoteSelectedProjectId) "✓ ${project.name}" else project.name) }
                }
            }
        }
        HorizontalDivider()
    }
}

private data class MobileFileBrowserEntry(val path: String, val name: String, val isDirectory: Boolean)

@Composable
private fun FilesScreen(projectID: String, root: () -> java.io.File, onImportFolder: () -> Unit, isImporting: Boolean) {
    var directory by remember(projectID) { mutableStateOf("") }
    var entries by remember(projectID) { mutableStateOf<List<MobileFileBrowserEntry>>(emptyList()) }
    var selected by remember { mutableStateOf<String?>(null) }
    var text by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val savedLocalMessage = stringResource(R.string.mobile_workspace_saved_local)
    val saveFailedMessage = stringResource(R.string.mobile_workspace_save_failed)

    fun refresh() {
        val relativeDirectory = directory
        scope.launch {
            entries = withContext(Dispatchers.IO) {
                val base = root()
                val current = if (relativeDirectory.isBlank()) base else AgentTools.resolve(base, relativeDirectory)
                current.listFiles().orEmpty()
                    .filterNot { java.nio.file.Files.isSymbolicLink(it.toPath()) || it.name.startsWith(".mem") }
                    .map { file ->
                        val path = if (relativeDirectory.isBlank()) file.name else "$relativeDirectory/${file.name}"
                        MobileFileBrowserEntry(path, file.name, file.isDirectory)
                    }
                    .sortedWith(compareBy<MobileFileBrowserEntry> { if (it.isDirectory) 0 else 1 }.thenBy { it.name.lowercase() })
            }
        }
    }

    LaunchedEffect(projectID, directory) {
        selected = null
        text = ""
        message = null
        refresh()
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (directory.isNotBlank()) {
                TextButton({ directory = directory.substringBeforeLast('/', "") }) { Text("‹") }
            }
            Text(directory.substringAfterLast('/').ifBlank { stringResource(R.string.conversation_files) }, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, maxLines = 1)
            if (isImporting) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                IconButton(onClick = onImportFolder) {
                    Icon(Icons.Filled.CreateNewFolder, contentDescription = stringResource(R.string.agent_choose_workspace))
                }
            }
            TextButton({ refresh() }) { Text(stringResource(R.string.common_refresh)) }
            Text(stringResource(R.string.mobile_workspace_local), style = MaterialTheme.typography.bodySmall)
        }
        HorizontalDivider()
        Row(Modifier.fillMaxSize()) {
            LazyColumn(Modifier.weight(0.38f)) {
                items(entries, key = { it.path }) { entry ->
                    TextButton({
                        if (entry.isDirectory) {
                            directory = entry.path
                        } else {
                            selected = entry.path
                            scope.launch {
                                text = withContext(Dispatchers.IO) { runCatching { AgentTools.resolve(root(), entry.path).readText() }.getOrDefault("") }
                                message = null
                            }
                        }
                    }, Modifier.fillMaxWidth()) {
                        Text(if (entry.isDirectory) "📁 ${entry.name}" else entry.name, maxLines = 1)
                    }
                }
            }
            Column(Modifier.weight(0.62f).fillMaxSize().padding(8.dp)) {
                Text(selected?.substringAfterLast('/') ?: stringResource(R.string.mobile_workspace_select_file), style = MaterialTheme.typography.titleMedium)
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
private fun AgentTab(
    agent: MobileAgent,
    client: RemoteClient,
    onLocateMissing: () -> Unit,
    canSwitchProject: Boolean,
    onProjectSelected: (String) -> Unit,
) {
    LocalAgentScreen(agent, client, onLocateMissing, canSwitchProject, onProjectSelected)
}

private data class MobileWelcomeCard(
    val icon: ImageVector,
    val title: String,
    val subtitle: String,
    val prompt: String,
)

@Composable
private fun MobileAgentWelcome(onChoose: (String) -> Unit) {
    val cards = listOf(
        MobileWelcomeCard(
            Icons.Filled.Search,
            stringResource(R.string.mobile_agent_new_conversation),
            stringResource(R.string.mobile_agent_ask),
            "Explore the current project and explain its structure, important files, and the best next step.",
        ),
        MobileWelcomeCard(
            Icons.Filled.Code,
            stringResource(R.string.mobile_workspace_code_editor),
            stringResource(R.string.mobile_workspace_local),
            "Help me build or improve the most useful next feature in this project. Start by inspecting the workspace.",
        ),
        MobileWelcomeCard(
            Icons.Filled.CheckCircle,
            stringResource(R.string.mobile_agent_plan),
            stringResource(R.string.mobile_agent_plan_subtitle),
            "Review the current project, identify risks and improvements, and prepare a concise implementation plan.",
        ),
        MobileWelcomeCard(
            Icons.Filled.Language,
            stringResource(R.string.mobile_preview_title),
            stringResource(R.string.mobile_preview_description),
            "Check the current project for anything that should be previewed or verified, then tell me what to open next.",
        ),
    )

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Image(
            painter = painterResource(R.drawable.herness_logo),
            contentDescription = null,
            modifier = Modifier.size(76.dp),
            contentScale = ContentScale.Fit,
        )
        Text("HerNess", fontSize = 30.sp, fontWeight = FontWeight.Bold)

        cards.chunked(2).forEach { rowCards ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                rowCards.forEach { card ->
                    OutlinedButton(
                        onClick = { onChoose(card.prompt) },
                        modifier = Modifier.weight(1f).heightIn(min = 112.dp),
                        shape = RoundedCornerShape(16.dp),
                        contentPadding = PaddingValues(12.dp),
                    ) {
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(7.dp), horizontalAlignment = Alignment.Start) {
                            Icon(card.icon, contentDescription = null, modifier = Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                            Text(card.title, style = MaterialTheme.typography.titleSmall, maxLines = 2)
                            Text(card.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3)
                        }
                    }
                }
                if (rowCards.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun HerNessLoadingAnimation(modifier: Modifier = Modifier) {
    val frames = remember {
        intArrayOf(
            R.drawable.herness_loader_frame_0,
            R.drawable.herness_loader_frame_1,
            R.drawable.herness_loader_frame_2,
            R.drawable.herness_loader_frame_3,
        )
    }
    var frame by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(220)
            frame = (frame + 1) % frames.size
        }
    }
    Image(
        painter = painterResource(frames[frame]),
        contentDescription = null,
        modifier = modifier,
    )
}

@Composable
private fun LocalAgentScreen(
    agent: MobileAgent,
    client: RemoteClient,
    onLocateMissing: () -> Unit,
    canSwitchProject: Boolean,
    onProjectSelected: (String) -> Unit,
) {
    var prompt by remember { mutableStateOf("") }
    var draftAttachments by remember { mutableStateOf<List<MobileAttachment>>(emptyList()) }
    var questionAnswer by remember { mutableStateOf("") }
    var showModels by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }
    var historyMode by remember { mutableIntStateOf(0) }
    var selectedHistoryId by remember { mutableStateOf<String?>(null) }
    var selectedHistoryPage by remember { mutableStateOf<StoredMobileMessagePage?>(null) }
    val transcriptListState = remember(agent.activeConversationId) { LazyListState() }
    var transcriptPositionedAtLatest by remember(agent.activeConversationId) { mutableStateOf(false) }
    var loadingOlderTranscript by remember(agent.activeConversationId) { mutableStateOf(false) }
    val historyListState = rememberLazyListState()
    var historyPositionedAtLatest by remember(selectedHistoryId) { mutableStateOf(false) }
    var loadingOlderHistory by remember(selectedHistoryId) { mutableStateOf(false) }
    var showCacheUsage by remember { mutableStateOf(false) }
    var showCacheResumeInfo by remember { mutableStateOf(false) }
    var cacheNoticeTick by remember { mutableIntStateOf(0) }
    val planSteps = MobilePlanSteps.current(agent.transcript)
    val latestPlanIndex = agent.transcript.indexOfLast { it.role == "tool" && it.toolName == MobilePlanSteps.NAME }
    val lastToolIndex = agent.transcript.indexOfLast { it.role == "tool" }
    val lastAssistantIndex = agent.transcript.indexOfLast { it.role == "assistant" }
    val completedPlan = planSteps.isNotEmpty()
        && !agent.running
        && agent.queuedPromptItems.isEmpty()
        && latestPlanIndex >= 0
        && !agent.transcript[latestPlanIndex].failed
        && !agent.transcript[latestPlanIndex].isRunning
        && lastAssistantIndex > lastToolIndex
    LaunchedEffect(agent.activeConversationId, agent.transcript.size, completedPlan) {
        if (!transcriptPositionedAtLatest && agent.transcript.isNotEmpty()) {
            val summaryIndex = agent.transcript.size + if (agent.hasOlderTranscriptMessages) 1 else 0
            transcriptListState.scrollToItem(if (completedPlan) summaryIndex else agent.transcript.lastIndex)
            transcriptPositionedAtLatest = true
        } else if (completedPlan) {
            val lastVisibleIndex = transcriptListState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
            if (lastVisibleIndex >= agent.transcript.size - 2) {
                val summaryIndex = agent.transcript.size + if (agent.hasOlderTranscriptMessages) 1 else 0
                transcriptListState.animateScrollToItem(summaryIndex)
            }
        }
    }
    LaunchedEffect(agent.activeConversationId) {
        snapshotFlow {
            Triple(
                transcriptPositionedAtLatest,
                transcriptListState.firstVisibleItemIndex,
                agent.hasOlderTranscriptMessages,
            )
        }.distinctUntilChanged().collect { (positioned, firstVisible, hasOlder) ->
            if (positioned && firstVisible == 0 && hasOlder && !loadingOlderTranscript) {
                loadingOlderTranscript = true
                agent.loadOlderTranscriptMessages()
                loadingOlderTranscript = false
            }
        }
    }
    LaunchedEffect(selectedHistoryId, selectedHistoryPage?.messages?.size) {
        val page = selectedHistoryPage
        if (selectedHistoryId != null && !historyPositionedAtLatest && page != null && page.messages.isNotEmpty()) {
            historyListState.scrollToItem(page.messages.lastIndex)
            historyPositionedAtLatest = true
        }
    }
    LaunchedEffect(selectedHistoryId) {
        snapshotFlow {
            Triple(
                historyPositionedAtLatest,
                historyListState.firstVisibleItemIndex,
                selectedHistoryPage?.hasOlder == true,
            )
        }.distinctUntilChanged().collect { (positioned, firstVisible, hasOlder) ->
            val id = selectedHistoryId
            val page = selectedHistoryPage
            val beforeRowId = page?.beforeRowId
            if (positioned && id != null && firstVisible == 0 && hasOlder && page != null && beforeRowId != null && !loadingOlderHistory) {
                loadingOlderHistory = true
                val olderPage = agent.storedMessagePage(id, beforeRowId)
                selectedHistoryPage = if (olderPage.messages.isEmpty()) {
                    page.copy(hasOlder = false)
                } else {
                    olderPage.copy(messages = olderPage.messages + page.messages)
                }
                loadingOlderHistory = false
            }
        }
    }
    LaunchedEffect(agent.activeConversationId) {
        while (true) {
            delay(30_000)
            cacheNoticeTick += 1
        }
    }
    val cacheResumeWarningVisible = cacheNoticeTick >= 0 && agent.expiredCachePrefixTokens != null
    val context = LocalContext.current
    val canSendPrompt = agent.isNoProjectMode || client.selectedProjectLocationAvailable
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        uris.forEach { uri ->
            runCatching {
                context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            MobileAttachment.fromUri(context, uri)?.let { attachment ->
                if (draftAttachments.none { it.sourceLocator == attachment.sourceLocator }) draftAttachments = draftAttachments + attachment
            }
        }
    }
    val speechInput = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val spokenText = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
        if (!spokenText.isNullOrBlank()) {
            prompt = listOf(prompt.trim(), spokenText.trim()).filter { it.isNotEmpty() }.joinToString(" ")
        }
    }
    Column(Modifier.fillMaxSize()) {
        if (agent.currentCacheSummary.events.isNotEmpty()) {
            TextButton({ showCacheUsage = true }, modifier = Modifier.fillMaxWidth()) {
                Text(agent.currentCacheSummary.label, style = MaterialTheme.typography.labelSmall, maxLines = 1)
            }
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            if (maxWidth < 560.dp) {
                Column(Modifier.fillMaxWidth()) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TextButton({ showModels = true }) { Text(agent.model, maxLines = 1) }
                        TextButton(
                            onClick = {
                                if (agent.isNoProjectMode) agent.selectProject(client.selectedProjectId)
                                else agent.selectNoProject()
                            },
                            enabled = !agent.running,
                        ) {
                            Text(stringResource(if (agent.isNoProjectMode) R.string.mobile_agent_use_project else R.string.mobile_agent_no_project), maxLines = 1)
                        }
                        TextButton({ agent.reset() }, enabled = agent.projectLocationAvailable) {
                            Text(stringResource(R.string.mobile_agent_new_conversation), maxLines = 1)
                        }
                        TextButton({ showHistory = true; selectedHistoryId = null }) {
                            Text(stringResource(R.string.sidebar_recent), maxLines = 1)
                        }
                    }
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Switch(
                            checked = agent.planMode,
                            onCheckedChange = { agent.planMode = it },
                            enabled = client.selectedProjectLocationAvailable && !agent.isNoProjectMode,
                        )
                        Text(stringResource(R.string.mobile_agent_plan), style = MaterialTheme.typography.labelSmall)
                    }
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton({ showModels = true }) { Text(agent.model, maxLines = 1) }
                    TextButton(
                        onClick = {
                            if (agent.isNoProjectMode) agent.selectProject(client.selectedProjectId)
                            else agent.selectNoProject()
                        },
                        enabled = !agent.running,
                    ) {
                        Text(stringResource(if (agent.isNoProjectMode) R.string.mobile_agent_use_project else R.string.mobile_agent_no_project), maxLines = 1)
                    }
                    TextButton({ agent.reset() }, enabled = agent.projectLocationAvailable) {
                        Text(stringResource(R.string.mobile_agent_new_conversation), maxLines = 1)
                    }
                    TextButton({ showHistory = true; selectedHistoryId = null }) { Text(stringResource(R.string.sidebar_recent), maxLines = 1) }
                    Switch(checked = agent.planMode, onCheckedChange = { agent.planMode = it }, enabled = client.selectedProjectLocationAvailable && !agent.isNoProjectMode)
                    Text(stringResource(R.string.mobile_agent_plan), style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        if (agent.requiresToolOutcomeRecovery) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(agent.toolOutcomeRecoveryMessage ?: "Çalışma kesintiye uğradı", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.weight(1f))
                    if (!agent.running) {
                        Button({ agent.continueRun() }, enabled = agent.projectLocationAvailable) { Text(stringResource(R.string.agent_continue)) }
                    }
                    if (agent.planGateIsActive) {
                        TextButton({ agent.cancelPlan() }) { Text(stringResource(R.string.mobile_agent_cancel_plan)) }
                    }
                }
            }
        }
        if (agent.pendingPlan && !agent.requiresToolOutcomeRecovery) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Button({ agent.applyPlan() }, enabled = !agent.running && client.selectedProjectLocationAvailable && !agent.isNoProjectMode) { Text(stringResource(R.string.mobile_agent_apply_plan)) }
                if (agent.waitingForPlan) Text(stringResource(R.string.mobile_queue_waiting_for_plan), style = MaterialTheme.typography.labelSmall)
                TextButton({ agent.cancelPlan() }) { Text(stringResource(R.string.mobile_agent_cancel_plan)) }
            }
        }
        if (agent.planGateIsActive && !agent.pendingPlan && !agent.requiresToolOutcomeRecovery) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(agent.providerLimitMessage ?: stringResource(R.string.mobile_agent_plan_paused), style = MaterialTheme.typography.labelSmall, color = if (agent.providerLimitMessage == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.weight(1f))
                    if (!agent.running) {
                        Button({ agent.continueRun() }, enabled = agent.projectLocationAvailable && !agent.isNoProjectMode) { Text(stringResource(R.string.mobile_agent_continue_plan)) }
                    }
                    TextButton({ agent.cancelPlan() }) { Text(stringResource(R.string.mobile_agent_cancel_plan)) }
                }
            }
        }
        if (!agent.planGateIsActive && agent.canContinueAfterProviderLimit) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                agent.providerLimitMessage?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error) }
                Row {
                    Spacer(Modifier.weight(1f))
                    Button({ agent.continueRun() }, enabled = agent.projectLocationAvailable) { Text(stringResource(R.string.agent_continue)) }
                }
            }
        }
        if (agent.queuedPromptItems.isNotEmpty()) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.mobile_agent_queued_messages), style = MaterialTheme.typography.labelSmall)
                agent.queuedPromptItems.forEach { queued ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(queued.text.ifBlank { "[Attachment]" }, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f), maxLines = 2)
                        OutlinedButton({ agent.promoteQueuedPrompt(queued.id) }, enabled = agent.projectLocationAvailable) {
                            Text(stringResource(R.string.mobile_agent_promote))
                        }
                    }
                }
            }
        }
        if (agent.transcript.isEmpty() && !agent.running) {
            if (agent.isNoProjectMode) {
                Text(stringResource(R.string.mobile_agent_no_project_help), modifier = Modifier.fillMaxWidth().padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                MobileAgentWelcome { prompt = it }
            }
        } else {
            LazyColumn(Modifier.weight(1f), state = transcriptListState) {
                items(agent.transcript, key = { it.id }) { turn ->
                    when (turn.role) {
                        "activity" -> Card(
                            Modifier.fillMaxWidth().padding(vertical = 4.dp),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                        ) {
                            Row(
                                Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(9.dp),
                            ) {
                                Text("↘", color = MaterialTheme.colorScheme.primary)
                                Column {
                                    Text(
                                        stringResource(contextCompactionResource(turn.toolName)),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    if (turn.text.isNotBlank()) Text(turn.text, style = MaterialTheme.typography.labelSmall)
                                }
                            }
                        }
                        "tool" -> {
                            var expanded by remember(turn.id) { mutableStateOf(false) }
                            Card(
                                Modifier.fillMaxWidth().padding(vertical = 2.dp),
                                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                Column(Modifier.padding(horizontal = 12.dp, vertical = 9.dp)) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                                        if (turn.isRunning) {
                                            HerNessLoadingAnimation(Modifier.size(16.dp))
                                        } else {
                                            Text(
                                                mobileToolActivityIcon(turn.toolName, turn.failed),
                                                color = if (turn.failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                                            )
                                        }
                                        Text(
                                            mobileToolActivityLabel(turn.toolName, turn.failed, turn.isRunning),
                                            style = MaterialTheme.typography.bodySmall,
                                            color = if (turn.failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                        if (turn.isRunning) ToolClock()
                                    }
                                    turn.activityDetail?.takeIf(String::isNotBlank)?.let { detail ->
                                        Text(
                                            detail,
                                            fontFamily = FontFamily.Monospace,
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
                                            maxLines = 2,
                                        )
                                    }
                                    if (!turn.isRunning) {
                                        TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) {
                                            Text(stringResource(if (expanded) R.string.mobile_activity_hide_details else R.string.mobile_activity_details))
                                        }
                                        if (expanded) Text(turn.text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, maxLines = 16)
                                    }
                                }
                            }
                        }
                        else -> Column(Modifier.padding(horizontal = 10.dp, vertical = 5.dp)) {
                            Text(
                                when (turn.role) {
                                    "user" -> stringResource(R.string.mobile_agent_user)
                                    "assistant" -> stringResource(R.string.conversation_assistant)
                                    "system" -> stringResource(R.string.mobile_event_run_summary)
                                    else -> stringResource(R.string.mobile_agent_error)
                                },
                                style = MaterialTheme.typography.labelMedium,
                                color = when (turn.role) { "error" -> MaterialTheme.colorScheme.error; "assistant" -> MaterialTheme.colorScheme.primary; "system" -> MaterialTheme.colorScheme.secondary; else -> MaterialTheme.colorScheme.onSurfaceVariant },
                            )
                            MarkdownBody(turn.text)
                            val latestAssistantID = agent.transcript.lastOrNull { it.role == "assistant" }?.id
                            val latestAssistantIndex = agent.transcript.indexOfLast { it.role == "assistant" }
                            val latestUserIndex = agent.transcript.indexOfLast { it.role == "user" }
                            val replies = MobileQuickReplySuggestions.choices(
                                turn.text,
                                stringResource(R.string.agent_continue),
                                stringResource(R.string.permission_reject),
                            )
                            if (turn.role == "assistant" && turn.id == latestAssistantID && latestAssistantIndex > latestUserIndex
                                && !agent.running && replies.isNotEmpty()) {
                                Row(
                                    Modifier.fillMaxWidth().padding(top = 6.dp),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    replies.forEachIndexed { index, reply ->
                                        if (index == 0) {
                                            Button(
                                                onClick = { agent.send(reply.text, mode = "queue", planMode = agent.planMode) },
                                                modifier = Modifier.weight(1f),
                                                enabled = client.selectedProjectLocationAvailable || agent.isNoProjectMode,
                                            ) { Text(reply.text, maxLines = 3) }
                                        } else {
                                            OutlinedButton(
                                                onClick = { agent.send(reply.text, mode = "queue", planMode = agent.planMode) },
                                                modifier = Modifier.weight(1f),
                                                enabled = client.selectedProjectLocationAvailable || agent.isNoProjectMode,
                                            ) { Text(reply.text, maxLines = 3) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (completedPlan) {
                    item(key = "completed-plan-${agent.activeConversationId}") {
                        Surface(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                            shape = RoundedCornerShape(10.dp),
                            color = MaterialTheme.colorScheme.surfaceVariant,
                        ) {
                            Column(Modifier.padding(9.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(
                                    "✓ ${stringResource(R.string.plan_title)} · ${planSteps.size}/${planSteps.size}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                planSteps.forEach { (title, _) ->
                                    Text(
                                        "✓  $title",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 2,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        agent.approvalRequest?.let { approval ->
            Column(Modifier.fillMaxWidth().padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.mobile_agent_approval_required), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(R.string.mobile_agent_allow_tool).replace("%@", approval.toolName))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button({ agent.answerApproval(approval.id, true) }, enabled = client.selectedProjectLocationAvailable) { Text(stringResource(R.string.permission_allow_once)) }
                    TextButton({ agent.answerApproval(approval.id, false) }, enabled = client.selectedProjectLocationAvailable) { Text(stringResource(R.string.permission_reject)) }
                }
            }
        }
        agent.questionRequest?.let { question ->
            if (question.askUserQuestions.isNotEmpty()) {
                MobileAskUserCard(
                    questions = question.askUserQuestions,
                    enabled = client.selectedProjectLocationAvailable,
                    onSubmit = { agent.answerQuestion(question.id, it) },
                    onSkip = { agent.answerQuestion(question.id, emptyList()) },
                )
            } else {
                Column(Modifier.fillMaxWidth().padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stringResource(R.string.mobile_agent_clarification), style = MaterialTheme.typography.titleSmall)
                    Text(question.question)
                    if (question.options.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            question.options.forEach { option ->
                                OutlinedButton({ agent.answerQuestion(question.id, listOf(option)) }, enabled = client.selectedProjectLocationAvailable) { Text(option) }
                            }
                        }
                    }
                    OutlinedTextField(questionAnswer, { questionAnswer = it }, Modifier.fillMaxWidth(), enabled = client.selectedProjectLocationAvailable, label = { Text(stringResource(R.string.mobile_agent_answer)) })
                    Button({
                        val answer = questionAnswer
                        questionAnswer = ""
                        agent.answerQuestion(question.id, listOf(answer))
                    }, enabled = client.selectedProjectLocationAvailable && questionAnswer.isNotBlank()) { Text(stringResource(R.string.mobile_agent_answer)) }
                }
            }
        }
        if (draftAttachments.isNotEmpty()) {
            Text("📎 " + draftAttachments.joinToString(", ") { it.displayName }, modifier = Modifier.padding(horizontal = 8.dp))
        }
        // Every row names a reason the next request costs more than the last one.
        val composerNotices = buildList {
            when (agent.routeSwitch) {
                MobileHarnessRuntime.RouteSwitch.ACCOUNT -> add(R.string.cache_account_switched_notice)
                MobileHarnessRuntime.RouteSwitch.MODEL -> add(R.string.cache_model_switched_notice)
                null -> Unit
            }
            // Both give the same new-chat advice; one is enough.
            if (cacheResumeWarningVisible) add(R.string.cache_resume_notice)
            else if (agent.contextNearlyFull) add(R.string.cache_context_full_notice)
        }
        composerNotices.forEach { notice ->
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)
                    .background(MaterialTheme.colorScheme.secondaryContainer, RoundedCornerShape(10.dp))
                    .padding(horizontal = 10.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    stringResource(notice),
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
                if (notice == R.string.cache_resume_notice) {
                    TextButton(
                        onClick = { showCacheResumeInfo = true },
                        modifier = Modifier.semantics { contentDescription = context.getString(R.string.cache_resume_info_title) },
                        contentPadding = PaddingValues(4.dp),
                    ) {
                        Text("ⓘ", color = MaterialTheme.colorScheme.onSecondaryContainer)
                    }
                }
            }
        }
        // Live checklist from the agent's latest update_plan, pinned above the composer.
        if (planSteps.isNotEmpty() && !completedPlan) {
            Surface(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
            ) {
                Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "☰ ${planSteps.count { it.second == "done" }}/${planSteps.size}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    planSteps.forEach { (title, status) ->
                        Text(
                            (when (status) { "done" -> "✓  "; "in_progress" -> "◌  "; else -> "○  " }) + title,
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = if (status == "in_progress") FontWeight.SemiBold else null,
                            color = if (status == "pending") MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                            maxLines = 2,
                        )
                    }
                }
            }
        }
        MobileProjectBranchBar(
            client = client,
            agent = agent,
            canSwitchProject = canSwitchProject,
            onProjectSelected = onProjectSelected,
            onLocateMissing = onLocateMissing,
        )
        Surface(
            modifier = Modifier.fillMaxWidth().padding(8.dp),
            shape = RoundedCornerShape(18.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            tonalElevation = 2.dp,
        ) {
            Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton({ picker.launch(arrayOf("*/*")) }, enabled = canSendPrompt) { Text("Attach") }
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { prompt = it },
                    modifier = Modifier.weight(1f),
                    enabled = canSendPrompt,
                    label = { Text(stringResource(R.string.mobile_agent_ask)) },
                    trailingIcon = {
                        IconButton(onClick = {
                            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                                putExtra(RecognizerIntent.EXTRA_LANGUAGE, java.util.Locale.getDefault().toLanguageTag())
                                putExtra(RecognizerIntent.EXTRA_PROMPT, context.getString(R.string.mobile_agent_dictate))
                            }
                            runCatching { speechInput.launch(intent) }
                        }) {
                            Icon(Icons.Filled.Mic, contentDescription = stringResource(R.string.mobile_agent_dictate))
                        }
                    },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        disabledContainerColor = Color.Transparent,
                        errorContainerColor = Color.Transparent,
                    ),
                )
                if (agent.running) {
                    HerNessLoadingAnimation(Modifier.size(18.dp))
                    Button({ if (agent.send(prompt, attachments = draftAttachments, mode = "queue", planMode = agent.planMode)) { prompt = ""; draftAttachments = emptyList() } }, enabled = canSendPrompt && (prompt.isNotBlank() || draftAttachments.isNotEmpty())) { Text(stringResource(R.string.mobile_agent_queue)) }
                    TextButton({ if (agent.send(prompt, attachments = draftAttachments, mode = "steer", planMode = agent.planMode)) { prompt = ""; draftAttachments = emptyList() } }, enabled = canSendPrompt && (prompt.isNotBlank() || draftAttachments.isNotEmpty())) { Text(stringResource(R.string.conversation_steer)) }
                    Button({ agent.cancel() }) { Text(stringResource(R.string.common_stop)) }
                } else {
                    Button({ if (agent.send(prompt, attachments = draftAttachments, mode = "queue", planMode = agent.planMode)) { prompt = ""; draftAttachments = emptyList() } }, enabled = canSendPrompt && (prompt.isNotBlank() || draftAttachments.isNotEmpty())) { Text(stringResource(R.string.mobile_agent_send)) }
                }
            }
        }
        agent.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 8.dp)) }
    }
    if (showCacheUsage) AlertDialog(
        onDismissRequest = { showCacheUsage = false },
        title = { Text("Cache") },
        text = { Text(agent.currentCacheSummary.details) },
        confirmButton = { TextButton({ showCacheUsage = false }) { Text("OK") } },
    )
    if (showCacheResumeInfo) AlertDialog(
        onDismissRequest = { showCacheResumeInfo = false },
        title = { Text(stringResource(R.string.cache_resume_info_title)) },
        text = { Text(stringResource(R.string.cache_resume_explanation)) },
        confirmButton = { TextButton({ showCacheResumeInfo = false }) { Text(stringResource(R.string.app_ok)) } },
    )
    if (showHistory) {
        val connectedProjectIds = client.projects
            .filter { java.io.File(it.localRoot).isDirectory }
            .map { it.id }
        val conversations = remember(historyMode, connectedProjectIds, agent.conversationListRevision) {
            when (historyMode) {
                1 -> agent.projectConversations()
                2 -> agent.archivedConversations()
                else -> agent.recentConversations(connectedProjectIds)
            }
        }
        val selectedMessages = selectedHistoryPage?.messages.orEmpty()
        AlertDialog(
            onDismissRequest = { showHistory = false; selectedHistoryId = null },
            title = {
                Text(when (historyMode) {
                    1 -> if (agent.isNoProjectMode) stringResource(R.string.mobile_agent_no_project) else client.selectedProject.name
                    2 -> stringResource(R.string.archive_title)
                    else -> stringResource(R.string.sidebar_recent)
                })
            },
            text = {
                Column(Modifier.heightIn(max = 480.dp).fillMaxWidth()) {
                    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                        TextButton(onClick = { historyMode = 0; selectedHistoryId = null; selectedHistoryPage = null }) {
                            Text(stringResource(R.string.sidebar_recent))
                        }
                        TextButton(onClick = { historyMode = 1; selectedHistoryId = null; selectedHistoryPage = null }) {
                            Text(if (agent.isNoProjectMode) stringResource(R.string.mobile_agent_no_project) else client.selectedProject.name)
                        }
                        TextButton(onClick = { historyMode = 2; selectedHistoryId = null; selectedHistoryPage = null }) {
                            Text(stringResource(R.string.archive_title))
                        }
                    }
                    if (selectedHistoryId != null) {
                        TextButton({ selectedHistoryId = null; selectedHistoryPage = null }) {
                            Text("‹ " + stringResource(R.string.sidebar_recent))
                        }
                    }
                    LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = historyListState) {
                        if (selectedHistoryId != null) {
                            items(selectedMessages, key = { it.rowId }) { message ->
                                Text(
                                    when (message.role) {
                                        "user" -> stringResource(R.string.mobile_agent_user)
                                        "assistant" -> stringResource(R.string.conversation_assistant)
                                        "tool" -> mobileToolActivityLabel(message.toolName)
                                        "activity" -> stringResource(contextCompactionResource(message.toolName))
                                        "error" -> stringResource(R.string.mobile_agent_error)
                                        else -> stringResource(R.string.mobile_event_run_summary)
                                    },
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                MarkdownBody(message.content, Modifier.padding(bottom = 10.dp))
                            }
                        } else if (conversations.isEmpty()) {
                            item {
                                Text(stringResource(if (historyMode == 2) R.string.archive_empty else R.string.sidebar_no_chats))
                            }
                        } else {
                            items(conversations, key = { it.id }) { conversation ->
                                Row(
                                    Modifier.fillMaxWidth(),
                                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                                ) {
                                    TextButton(
                                        onClick = {
                                            selectedHistoryId = conversation.id
                                            selectedHistoryPage = agent.storedMessagePage(conversation.id)
                                        },
                                        modifier = Modifier.weight(1f),
                                    ) {
                                        Column(Modifier.fillMaxWidth()) {
                                            Text(conversation.title.ifBlank {
                                                java.text.DateFormat.getDateTimeInstance().format(java.util.Date(conversation.updatedAt))
                                            }, maxLines = 2)
                                            Text(conversation.status.replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.labelSmall)
                                        }
                                    }
                                    TextButton(
                                        onClick = {
                                            if (historyMode == 2) {
                                                agent.restoreConversation(conversation.id)
                                            } else {
                                                val wasActive = conversation.id == agent.activeConversationId
                                                if (agent.archiveConversation(conversation.id)) {
                                                    if (wasActive) {
                                                        showHistory = false
                                                        selectedHistoryId = null
                                                        selectedHistoryPage = null
                                                    } else {
                                                        historyMode = 2
                                                        selectedHistoryId = null
                                                        selectedHistoryPage = null
                                                    }
                                                }
                                            }
                                        },
                                        enabled = !agent.running && (historyMode == 2
                                            || conversation.id != agent.activeConversationId
                                            || agent.projectLocationAvailable),
                                    ) {
                                        Text(stringResource(if (historyMode == 2) R.string.archive_restore else R.string.sidebar_archive_chat))
                                    }
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton({ showHistory = false; selectedHistoryId = null; selectedHistoryPage = null }) { Text(stringResource(R.string.mobile_agent_close)) } },
        )
    }
    if (showModels) AlertDialog(
        onDismissRequest = { showModels = false },
        title = { Text(stringResource(R.string.mobile_agent_model)) },
        text = {
            Column {
                MobileHarnessRuntime.PROVIDER_DEFINITIONS.forEach { definition ->
                    TextButton({ agent.selectProvider(definition.id) }) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            MobileProviderBrandMark(definition.id, Modifier.size(20.dp))
                            Text(definition.name)
                        }
                    }
                }
                if (agent.supportsFast) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.mobile_agent_fast), Modifier.weight(1f))
                    Switch(checked = agent.fastMode, onCheckedChange = agent::updateFastMode)
                }
                agent.availableModelsFor(agent.provider).forEach { value ->
                    TextButton({ agent.selectModel(value); showModels = false }) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            MobileProviderBrandMark(agent.provider, Modifier.size(18.dp))
                            Text(value)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton({ showModels = false }) { Text(stringResource(R.string.mobile_agent_close)) } },
    )
}

/** Terminal tab: the constrained mobile runtime, never an implicit desktop shell. */
@Composable
private fun MobileAskUserCard(
    questions: List<MobileAskUserQuestion>,
    enabled: Boolean,
    onSubmit: (List<String>) -> Unit,
    onSkip: () -> Unit,
) {
    var page by remember(questions) { mutableIntStateOf(0) }
    var selections by remember(questions) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var customAnswers by remember(questions) { mutableStateOf<Map<String, String>>(emptyMap()) }
    if (questions.isEmpty()) return
    val current = questions[page.coerceIn(questions.indices)]
    val isLast = page == questions.lastIndex
    val defaultHeader = stringResource(R.string.ask_default_header, page + 1)

    fun answer(question: MobileAskUserQuestion): String {
        val custom = customAnswers[question.id].orEmpty().trim()
        return custom.ifBlank { selections[question.id].orEmpty() }
    }

    fun choose(option: String) {
        val updated = selections.toMutableMap()
        if (updated[current.id] == option) updated.remove(current.id) else updated[current.id] = option
        selections = updated
        customAnswers = customAnswers.toMutableMap().apply { remove(current.id) }
    }

    Card(
        modifier = Modifier.fillMaxWidth().padding(8.dp),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Text(stringResource(R.string.mobile_agent_clarification), style = MaterialTheme.typography.titleSmall)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "${page + 1}/${questions.size}",
                    color = MaterialTheme.colorScheme.tertiary,
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.background(MaterialTheme.colorScheme.tertiaryContainer, RoundedCornerShape(50)).padding(horizontal = 9.dp, vertical = 4.dp),
                )
                Text(
                    current.header.ifBlank { defaultHeader },
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(current.prompt, style = MaterialTheme.typography.bodyMedium)

            current.options.forEach { option ->
                val selected = selections[current.id] == option
                val parts = option.split(" — ", limit = 2).takeIf { it.size == 2 }
                    ?: option.split(": ", limit = 2).takeIf { it.size == 2 }
                Card(
                    modifier = Modifier.fillMaxWidth().clickable(enabled = enabled) { choose(option) },
                    shape = RoundedCornerShape(10.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                    ),
                ) {
                    Row(Modifier.padding(start = 10.dp, end = 4.dp, top = 3.dp, bottom = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f).padding(vertical = 5.dp)) {
                            Text(parts?.get(0) ?: option, style = MaterialTheme.typography.bodyMedium)
                            parts?.getOrNull(1)?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                        Checkbox(checked = selected, onCheckedChange = { choose(option) }, enabled = enabled)
                    }
                }
            }

            OutlinedTextField(
                value = customAnswers[current.id].orEmpty(),
                onValueChange = { value ->
                    customAnswers = customAnswers.toMutableMap().apply { put(current.id, value) }
                    if (value.isNotBlank()) selections = selections.toMutableMap().apply { remove(current.id) }
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = enabled,
                minLines = 1,
                maxLines = 4,
                label = { Text(stringResource(R.string.ask_other)) },
                placeholder = { Text(stringResource(R.string.ask_custom_placeholder)) },
            )

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(onClick = onSkip, enabled = enabled) { Text(stringResource(R.string.ask_skip_short)) }
                Spacer(Modifier.weight(1f))
                if (isLast) {
                    Button(onClick = { onSubmit(questions.map { answer(it) }) }, enabled = enabled) {
                        Text(stringResource(R.string.ask_submit))
                    }
                } else {
                    Button(onClick = { page++ }, enabled = enabled) { Text(stringResource(R.string.ask_next)) }
                }
            }
        }
    }
}

@Composable
private fun TerminalTab(shell: LocalShell, client: RemoteClient) {
    PhoneTerminalScreen(shell, client)
}

@Composable
private fun PhoneTerminalScreen(shell: LocalShell, client: RemoteClient) {
    var command by remember { mutableStateOf("") }
    var useRemote by remember { mutableStateOf(false) }
    var remoteOutput by remember { mutableStateOf("") }
    var remoteRunning by remember { mutableStateOf(false) }
    var remoteMessage by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val remoteAvailable = client.paired && client.remoteProjectMatchesSelectedProject
    val approvalHint = stringResource(R.string.mobile_terminal_approval_hint)
    val startFailed = stringResource(R.string.mobile_terminal_start_failed)

    suspend fun refreshRemote(action: String = "read", input: String? = null) {
        try {
            val response = client.command("terminal_session", buildMap {
                put("action", action)
                if (input != null) put("input", input)
            })
            if (response.status == "approval-required") {
                remoteMessage = approvalHint
                return
            }
            response.error?.takeIf { it.isNotBlank() }?.let { error(it) }
            val result = runCatching { JSONObject(response.result ?: "{}") }.getOrNull()
            remoteRunning = result?.optBoolean("running") ?: false
            remoteOutput = result?.optString("output").orEmpty()
            if (remoteRunning) remoteMessage = ""
            else if (action == "start") remoteMessage = startFailed
        } catch (t: Throwable) {
            remoteMessage = t.message ?: startFailed
        }
    }

    LaunchedEffect(useRemote, remoteAvailable, client.selectedProjectId) {
        if (useRemote && remoteAvailable) {
            refreshRemote()
            while (isActive) {
                delay(800)
                refreshRemote()
            }
        } else if (!remoteAvailable) {
            useRemote = false
            remoteRunning = false
            remoteOutput = ""
        }
    }

    Column(Modifier.fillMaxSize()) {
        if (remoteAvailable) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { useRemote = false }, enabled = useRemote) { Text(stringResource(R.string.mobile_terminal_phone_runtime)) }
                Button(onClick = { useRemote = true }, enabled = !useRemote) { Text(stringResource(R.string.mobile_terminal_desktop_runtime)) }
                Spacer(Modifier.weight(1f))
                Button(onClick = { scope.launch { refreshRemote("start") } }, enabled = useRemote && !remoteRunning) { Text(stringResource(R.string.mobile_terminal_start)) }
                if (useRemote && remoteRunning) {
                    OutlinedButton(onClick = { scope.launch { refreshRemote("stop") }; remoteRunning = false }) { Text(stringResource(R.string.mobile_terminal_stop)) }
                }
            }
        }
        if (useRemote) {
            Text(
                remoteMessage.ifBlank { stringResource(if (remoteRunning) R.string.mobile_terminal_session_active else R.string.mobile_terminal_session_paused) },
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 3.dp),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("./run.sh", "npm run dev", "npm test", "npm run build", "git status", "git diff").forEach { value ->
                    OutlinedButton(onClick = { command = value; scope.launch { refreshRemote("send", "$value\n") } }, enabled = remoteRunning) {
                        Text(value, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall)
                    }
                }
                OutlinedButton(onClick = { scope.launch { refreshRemote("send", "\u0003") } }, enabled = remoteRunning) { Text("Ctrl-C") }
            }
        }
        val terminalText = if (useRemote) remoteOutput else shell.lines.joinToString("\n")
        LazyColumn(Modifier.weight(1f).fillMaxWidth().background(Color(0xFF0B0B0B)).padding(8.dp)) {
            items(terminalText.lineSequence().toList().takeLast(600)) { line -> Text(line, fontFamily = FontFamily.Monospace, color = Color(0xFF4CE04C), style = MaterialTheme.typography.bodySmall) }
        }
        Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (useRemote) "desktop ›" else shell.prompt, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(command, { command = it }, Modifier.weight(1f), label = { Text("ls -l") }, textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
            Button({
                val value = command
                command = ""
                if (useRemote) scope.launch { refreshRemote("send", "$value\n") } else scope.launch { shell.run(value) }
            }, enabled = command.isNotBlank() && (!useRemote || remoteRunning)) { Text(stringResource(R.string.mobile_terminal_run)) }
        }
    }
}

@Composable
private fun PreviewScreen(client: RemoteClient) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("herness.preferences", Activity.MODE_PRIVATE) }
    val projectID = client.selectedProjectId
    var url by remember(projectID) { mutableStateOf(prefs.getString("pages.preview.$projectID", "").orEmpty()) }
    var activeUrl by remember(projectID) { mutableStateOf("") }
    var port by remember(projectID) { mutableStateOf("3000") }
    var message by remember(projectID) { mutableStateOf("") }
    var webView by remember(projectID) { mutableStateOf<WebView?>(null) }
    var requestedUrl by remember(projectID) { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val remoteAvailable = client.paired && client.remoteProjectMatchesSelectedProject
    val approvalHint = stringResource(R.string.mobile_preview_approval_hint)
    val previewError = stringResource(R.string.mobile_preview_error)
    val openLabel = stringResource(R.string.mobile_preview_open)
    LaunchedEffect(projectID) {
        url = prefs.getString("pages.preview.$projectID", "").orEmpty()
        if (url.startsWith("http://") || url.startsWith("https://")) activeUrl = url
    }

    fun openPreview(candidate: String = url) {
        val normalized = candidate.trim().let { if (it.startsWith("http://") || it.startsWith("https://")) it else "https://$it" }
        if (runCatching { URI(normalized) }.getOrNull()?.host.isNullOrBlank()) {
            message = previewError
            return
        }
        url = normalized
        prefs.edit().putString("pages.preview.$projectID", normalized).apply()
        activeUrl = normalized
        message = ""
    }

    Column(Modifier.fillMaxSize().padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            OutlinedTextField(url, { url = it }, Modifier.weight(1f), singleLine = true, label = { Text(stringResource(R.string.mobile_preview_url)) })
            Button(onClick = { openPreview() }) { Text(openLabel) }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            OutlinedButton(onClick = { webView?.goBack() }, enabled = webView?.canGoBack() == true) { Text("‹") }
            OutlinedButton(onClick = { webView?.goForward() }, enabled = webView?.canGoForward() == true) { Text("›") }
            OutlinedButton(onClick = { webView?.reload() }, enabled = activeUrl.isNotEmpty()) { Text("↻") }
        }
        if (remoteAvailable) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                OutlinedTextField(port, { port = it.filter(Char::isDigit).take(5) }, Modifier.weight(1f), singleLine = true, label = { Text(stringResource(R.string.mobile_preview_port)) }, keyboardOptions = KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number))
                Button(onClick = {
                    scope.launch {
                        message = ""
                        try {
                            val response = client.command("preview_tunnel", mapOf("action" to "start", "port" to port.toIntOrNull()))
                            if (response.status == "approval-required") { message = approvalHint; return@launch }
                            response.error?.takeIf { it.isNotBlank() }?.let { error(it) }
                            val result = JSONObject(response.result ?: "{}")
                            val sharedUrl = result.optString("url")
                            if (sharedUrl.isNotBlank()) openPreview(sharedUrl)
                        } catch (t: Throwable) { message = t.message ?: previewError }
                    }
                }, enabled = port.isNotBlank()) { Text(stringResource(R.string.mobile_preview_share_port)) }
                OutlinedButton(onClick = { scope.launch { runCatching { client.command("preview_tunnel", mapOf("action" to "stop")) }; message = "" } }) {
                    Text(stringResource(R.string.mobile_preview_stop_sharing))
                }
            }
            Text(stringResource(R.string.mobile_preview_public_hint), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (message.isNotBlank()) Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        if (activeUrl.isNotBlank()) {
            AndroidView(
                factory = { viewContext -> WebView(viewContext).apply {
                    webViewClient = WebViewClient()
                    settings.javaScriptEnabled = true
                    webView = this
                    if (activeUrl.isNotBlank()) { requestedUrl = activeUrl; loadUrl(activeUrl) }
                } },
                modifier = Modifier.weight(1f).fillMaxWidth(),
                update = { view -> if (activeUrl.isNotBlank() && requestedUrl != activeUrl) { requestedUrl = activeUrl; view.loadUrl(activeUrl) } },
            )
        } else {
            Text(stringResource(R.string.mobile_preview_pages_hint), Modifier.padding(12.dp))
        }
    }
}


/** MCP servers and JS plugins: both extend the phone agent's tool set. */

/**
 * Collects the workspace with the same exclusions the agent sees, applies phone-side
 * upload caps (5 MB per file, 50 MB total, 5000 files), deploys through Cloudflare's
 * direct-upload endpoint, and stores the result URL so the Preview tab opens on it.
 */
private suspend fun deployToPages(
    client: RemoteClient,
    accountId: String,
    project: String,
    token: String,
    projectID: String,
    preferences: android.content.SharedPreferences,
): String {
    val root = client.workspaceRoot()
    return try {
        val bundle = linkedMapOf<String, ByteArray>()
        var total = 0L
        var skipped = 0
        for (path in AgentTools.walk(root)) {
            val file = runCatching { AgentTools.resolve(root, path) }.getOrNull() ?: continue
            val bytes = runCatching { file.readBytes() }.getOrNull() ?: continue
            if (bytes.size > MAX_PAGE_FILE_BYTES || total + bytes.size > MAX_PAGE_TOTAL_BYTES || bundle.size >= MAX_PAGE_FILE_COUNT) { skipped += 1; continue }
            bundle[path] = bytes
            total += bytes.size
        }
        if (bundle.isEmpty()) return "No files to deploy."
        val url = PagesDeployClient(accountId.trim(), token.trim()).deploy(project.trim(), bundle)
        preferences.edit().putString("pages.preview.$projectID", url).apply()
        val note = if (skipped > 0) " ($skipped files skipped by size limits)." else "."
        "Deployed ${bundle.size} files to $url$note"
    } catch (t: Throwable) {
        "Deploy failed: ${t.message ?: "Cloudflare Pages deploy failed."}"
    }
}

private const val MAX_PAGE_FILE_BYTES = 5 * 1024 * 1024
private const val MAX_PAGE_TOTAL_BYTES = 50 * 1024 * 1024
private const val MAX_PAGE_FILE_COUNT = 5000

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
private fun TasksScreen(loops: LoopScheduler) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        LoopsSection(loops)
    }
}

@Composable
private fun MemoryScreen(client: RemoteClient, userRoot: java.io.File) {
    val root = client.workspaceRoot()
    var kind by remember { mutableStateOf("project") }
    var scope by remember { mutableStateOf("user") }
    var key by remember { mutableStateOf("") }
    var value by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var refresh by remember { mutableIntStateOf(0) }
    var deleteTarget by remember { mutableStateOf<MobileFacts.Entry?>(null) }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.vault_section_project), style = MaterialTheme.typography.titleMedium)
        if (MobileFacts.needsTrust(root, userRoot)) {
            Text(stringResource(R.string.memory_trust_prompt), style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button({ MobileFacts.setTrust(true, root, userRoot); refresh++ }) { Text(stringResource(R.string.memory_trust_yes)) }
                OutlinedButton({ MobileFacts.setTrust(false, root, userRoot); refresh++ }) { Text(stringResource(R.string.memory_trust_no)) }
            }
        }
        if (MobileFacts.trust(root, userRoot) == false) {
            Text(MobileFacts.text(root, userRoot), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        val projectEntries = remember(root, refresh) { MobileFacts.entries(root).filter { it.kind != "preference" } }
        projectEntries.forEach { entry ->
            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(entry.key, style = MaterialTheme.typography.titleSmall)
                        Text(entry.text, style = MaterialTheme.typography.bodySmall)
                    }
                    IconButton(onClick = { deleteTarget = entry }) {
                        Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.common_delete))
                    }
                }
            }
        }

        Text(stringResource(R.string.vault_section_profile), style = MaterialTheme.typography.titleMedium)
        val personalMemory = remember(root, refresh) { MobilePersonalMemory.text(userRoot, root) }
        if (personalMemory.isNotEmpty()) Text(personalMemory, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

        HorizontalDivider()
        Text(stringResource(R.string.vault_new), style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { kind = "project" }) {
                Text(stringResource(R.string.vault_new_project_entry))
            }
            OutlinedButton(onClick = { kind = "preference" }) {
                Text(stringResource(R.string.vault_new_preference))
            }
        }
        OutlinedTextField(
            key,
            { key = it },
            Modifier.fillMaxWidth(),
            label = { Text(stringResource(R.string.vault_entry_key_language)) },
            singleLine = true,
        )
        OutlinedTextField(
            value,
            { value = it },
            Modifier.fillMaxWidth(),
            label = { Text(stringResource(R.string.vault_entry_value)) },
            minLines = 2,
            maxLines = 5,
        )
        if (kind == "preference") {
            Text(stringResource(R.string.vault_entry_scope), style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { scope = "user" }) {
                    Text(stringResource(R.string.vault_entry_everywhere))
                }
                OutlinedButton(onClick = { scope = "project" }) {
                    Text(stringResource(R.string.vault_entry_this_project))
                }
            }
        }
        Button(
            onClick = {
                status = MobileFacts.record(root, kind, key, value, scope, userRoot)
                value = ""
                refresh++
            },
            enabled = client.selectedProjectLocationAvailable && key.isNotBlank() && value.isNotBlank(),
        ) { Text(stringResource(R.string.common_save)) }
        if (status.isNotBlank()) Text(status, style = MaterialTheme.typography.bodySmall)
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text(stringResource(R.string.vault_delete_confirm)) },
            confirmButton = {
                TextButton({
                    MobileFacts.remove(root, target.kind, target.key)
                    deleteTarget = null
                    refresh++
                }) { Text(stringResource(R.string.common_delete)) }
            },
            dismissButton = {
                TextButton({ deleteTarget = null }) { Text(stringResource(R.string.common_cancel)) }
            },
        )
    }
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
    Button({ agent.replaceProjectTools(plugins.reload()); agent.pluginPrompt = plugins.promptSections.joinToString("\n") }) { Text(stringResource(R.string.mobile_plugins_reload)) }
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
    isDarkTheme: Boolean,
    onThemeToggle: () -> Unit,
    confirmBeforeExit: Boolean,
    onConfirmBeforeExitChange: (Boolean) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val settingsScroll = rememberScrollState()
    var providerKey by remember { mutableStateOf(client.phoneSecret("provider.${agent.provider}")) }
    var providerKeyStored by remember { mutableStateOf(providerKey.isNotBlank()) }
    var showProviderModels by remember { mutableStateOf(false) }
    var showChatGPTAccounts by remember { mutableStateOf(false) }
    var settingsTab by remember { mutableIntStateOf(0) }
    var compactPercentText by remember(agent.contextCompactionThresholdPercent) {
        mutableStateOf(agent.contextCompactionThresholdPercent.toString())
    }
    val selectedProvider = MobileHarnessRuntime.definition(agent.provider)
        ?: MobileHarnessRuntime.PROVIDER_DEFINITIONS.first()
    
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
    val hernessPreferences = remember { context.getSharedPreferences("herness.preferences", Activity.MODE_PRIVATE) }
    var pagesAccountId by remember { mutableStateOf(hernessPreferences.getString("pages.accountId", "").orEmpty()) }
    var pagesProject by remember { mutableStateOf(hernessPreferences.getString("pages.project", "").orEmpty()) }
    var pagesToken by remember { mutableStateOf(client.phoneSecret("pages.token")) }
    var pagesStatus by remember { mutableStateOf("") }
    var pagesBusy by remember { mutableStateOf(false) }

    LaunchedEffect(agent.provider) {
        providerKey = client.phoneSecret("provider.${agent.provider}")
        providerKeyStored = providerKey.isNotBlank()
    }
    LaunchedEffect(settingsTab) {
        settingsScroll.scrollTo(0)
    }
    LaunchedEffect(settingsTab, agent.provider) {
        if (settingsTab == 1) agent.refreshModelsIfNeeded()
    }
    LaunchedEffect(chatGPT.accountId) {
        if (agent.provider == "gpt") agent.refreshModelsIfNeeded(force = true)
    }

    val settingsTabs = listOf(
        stringResource(R.string.settings_tab_general),
        stringResource(R.string.settings_tab_providers),
        stringResource(R.string.settings_tab_accounts),
        stringResource(R.string.settings_tab_repository),
        stringResource(R.string.settings_tab_tools),
    )

    Column(Modifier.fillMaxSize().background(if (isDarkTheme) Color.Black else Color.White)) {
        ScrollableTabRow(
            selectedTabIndex = settingsTab,
            edgePadding = 16.dp,
            containerColor = if (isDarkTheme) Color.Black else Color.White,
        ) {
            settingsTabs.forEachIndexed { index, label ->
                Tab(selected = settingsTab == index, onClick = { settingsTab = index }, text = { Text(label) })
            }
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(settingsScroll).padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(24.dp),
                color = if (isDarkTheme) Color.Black else Color.White,
                contentColor = MaterialTheme.colorScheme.onSurface,
                tonalElevation = 0.dp,
            ) {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (settingsTab == 0) {
                Text(stringResource(R.string.intro_language), style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(selectedLanguage.nativeName, Modifier.weight(1f))
                    CustomLanguagePicker(selectedLanguage, onLanguageChange, darkAppearance = isDarkTheme)
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Dark Mode", Modifier.weight(1f))
                    Switch(checked = isDarkTheme, onCheckedChange = { onThemeToggle() })
                }
                Text(stringResource(R.string.mobile_agent_plan_settings_section), style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.mobile_agent_auto_approve_plans))
                        Text(stringResource(R.string.mobile_agent_auto_approve_plans_hint), style = MaterialTheme.typography.bodySmall)
                    }
                    Switch(checked = agent.autoApprovePlans, onCheckedChange = agent::updateAutoApprovePlans)
                }
                Text(stringResource(R.string.mobile_agent_subagents_section), style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.mobile_agent_subagents))
                        Text(stringResource(R.string.mobile_agent_subagents_hint), style = MaterialTheme.typography.bodySmall)
                    }
                    Switch(checked = agent.subagentsEnabled, onCheckedChange = agent::updateSubagentsEnabled)
                }
                Text(stringResource(R.string.settings_compact_trigger), style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        val next = (compactPercentText.toIntOrNull() ?: agent.contextCompactionThresholdPercent) - 1
                        agent.updateContextCompactionThresholdPercent(next)
                        compactPercentText = agent.contextCompactionThresholdPercent.toString()
                    }) { Text("−") }
                    OutlinedTextField(
                        value = compactPercentText,
                        onValueChange = { raw ->
                            val digits = raw.filter(Char::isDigit).take(3)
                            val entered = digits.toIntOrNull()
                            val bounded = entered?.coerceIn(0, 100)
                            compactPercentText = if (entered != null && entered > 100) bounded.toString() else digits
                            bounded?.let(agent::updateContextCompactionThresholdPercent)
                        },
                        modifier = Modifier.width(88.dp),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        label = { Text("%") },
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = Color.Transparent,
                            unfocusedContainerColor = Color.Transparent,
                        ),
                    )
                    OutlinedButton(onClick = {
                        val next = (compactPercentText.toIntOrNull() ?: agent.contextCompactionThresholdPercent) + 1
                        agent.updateContextCompactionThresholdPercent(next)
                        compactPercentText = agent.contextCompactionThresholdPercent.toString()
                    }) { Text("+") }
                }
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

            if (settingsTab == 1) {
                Text(stringResource(R.string.settings_tab_providers), style = MaterialTheme.typography.headlineSmall)
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    MobileHarnessRuntime.PROVIDER_DEFINITIONS.forEach { definition ->
                        OutlinedButton(
                            onClick = { agent.selectProvider(definition.id) },
                            border = BorderStroke(
                                if (definition.id == agent.provider) 2.dp else 1.dp,
                                if (definition.id == agent.provider) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                            ),
                        ) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                MobileProviderBrandMark(definition.id, Modifier.size(20.dp))
                                Text(definition.name)
                            }
                        }
                    }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            MobileProviderBrandMark(selectedProvider.id, Modifier.size(22.dp))
                            Text(selectedProvider.name, style = MaterialTheme.typography.titleMedium)
                        }
                        Text(
                            stringResource(
                                if (!selectedProvider.requiresApiKey) R.string.mobile_settings_provider_oauth
                                else if (providerKeyStored) R.string.mobile_settings_provider_stored
                                else R.string.mobile_settings_provider_missing,
                            ),
                            color = if (!selectedProvider.requiresApiKey || providerKeyStored) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    OutlinedButton({ showProviderModels = true }) { Text(agent.model) }
                }
                if (selectedProvider.requiresApiKey) {
                    OutlinedTextField(
                        providerKey,
                        { providerKey = it },
                        Modifier.fillMaxWidth(),
                        label = { Text(stringResource(R.string.mobile_settings_provider_key)) },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            {
                                client.savePhoneSecret("provider.${agent.provider}", providerKey)
                                providerKeyStored = providerKey.isNotBlank()
                                scope.launch { agent.refreshModelsIfNeeded(force = true) }
                            },
                            enabled = providerKey.isNotBlank(),
                        ) { Text(stringResource(R.string.mobile_settings_save_provider_key)) }
                        if (providerKeyStored) {
                            TextButton({
                                client.savePhoneSecret("provider.${agent.provider}", "")
                                providerKey = ""
                                providerKeyStored = false
                            }) { Text(stringResource(R.string.common_remove)) }
                        }
                    }
                } else {
                    Text(stringResource(R.string.mobile_settings_gpt_hint), style = MaterialTheme.typography.bodySmall)
                }
                Text(stringResource(R.string.mobile_settings_provider_key_hint), style = MaterialTheme.typography.bodySmall)
            }

            if (settingsTab == 2) {
                Text(stringResource(R.string.mobile_settings_gpt_account), style = MaterialTheme.typography.titleMedium)
                if (chatGPT.accounts.isNotEmpty()) {
                    Box {
                        OutlinedButton({ showChatGPTAccounts = true }) {
                            Text(chatGPT.accounts.firstOrNull { it.id == chatGPT.accountId }?.title ?: "ChatGPT")
                        }
                        DropdownMenu(expanded = showChatGPTAccounts, onDismissRequest = { showChatGPTAccounts = false }) {
                            chatGPT.accounts.forEach { account ->
                                DropdownMenuItem(
                                    text = { Text(account.title) },
                                    onClick = {
                                        chatGPT.selectAccount(account.id)
                                        showChatGPTAccounts = false
                                        scope.launch { agent.refreshModelsIfNeeded(force = true) }
                                    },
                                )
                            }
                        }
                    }
                    Text("ChatGPT " + stringResource(R.string.mobile_settings_connected), color = MaterialTheme.colorScheme.primary)
                    TextButton({ chatGPT.signOut() }) { Text(stringResource(R.string.mobile_settings_sign_out)) }
                }
                Button({ chatGPT.start(context as? Activity) }, enabled = !chatGPT.signingIn) {
                    Text(if (chatGPT.signingIn) stringResource(R.string.mobile_settings_waiting_chat_gpt) else stringResource(R.string.mobile_settings_sign_in_chat_gpt))
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
            }

            if (settingsTab == 3) {
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
            }

            if (settingsTab == 4) {
                Text("Sites (Cloudflare Pages)", style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(pagesAccountId, { pagesAccountId = it; hernessPreferences.edit().putString("pages.accountId", it).apply() }, Modifier.fillMaxWidth(), label = { Text("Account ID") })
                OutlinedTextField(pagesProject, { pagesProject = it; hernessPreferences.edit().putString("pages.project", it).apply() }, Modifier.fillMaxWidth(), label = { Text("Pages project name") })
                OutlinedTextField(pagesToken, { pagesToken = it }, Modifier.fillMaxWidth(), label = { Text("API token (stored in phone keychain)") })
                Button(
                    {
                        client.savePhoneSecret("pages.token", pagesToken)
                        pagesBusy = true
                        pagesStatus = "Collecting files…"
                        scope.launch {
                            pagesStatus = deployToPages(client, pagesAccountId, pagesProject, pagesToken, client.selectedProjectId, hernessPreferences)
                            pagesBusy = false
                        }
                    },
                    enabled = !pagesBusy && pagesAccountId.isNotBlank() && pagesProject.isNotBlank() && pagesToken.isNotBlank(),
                ) { Text("Deploy workspace") }
                if (pagesStatus.isNotBlank()) Text(pagesStatus, style = MaterialTheme.typography.bodySmall)
                McpAndPluginsSection(agent, plugins, mcp)
            }
        }
            }
        }
    }
    if (showProviderModels) AlertDialog(
        onDismissRequest = { showProviderModels = false },
        title = { Text(stringResource(R.string.mobile_agent_model)) },
        text = {
            Column {
                agent.availableModelsFor(agent.provider).forEach { value ->
                    TextButton({ agent.selectModel(value); showProviderModels = false }) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            MobileProviderBrandMark(agent.provider, Modifier.size(18.dp))
                            Text(value)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton({ showProviderModels = false }) { Text(stringResource(R.string.mobile_agent_close)) } },
    )
}

private fun contextCompactionResource(code: String?): Int =
    if (code == "context_compacted_auto") R.string.conversation_context_compacted_auto
    else R.string.status_context_compacted

@Composable
private fun mobileToolActivityLabel(toolName: String?, failed: Boolean = false, running: Boolean = false): String {
    val name = toolName.orEmpty()
    if (failed) return stringResource(R.string.conversation_activity_tool_failed).replace("%@", name.replace('_', ' '))
    val key = when (name.lowercase()) {
        "read_file", "list_files", "grep_files", "glob_files", "search_files", "get_latest_attachment" -> if (running) R.string.conversation_activity_files_reading else R.string.conversation_activity_files_read
        "write_file", "edit_file", "create_file", "delete_file", "copy_generated_media" -> if (running) R.string.conversation_activity_files_changing else R.string.conversation_activity_files_changed
        "run_command", "terminal_session", "shell", "exec" -> if (running) R.string.conversation_activity_commands_running else R.string.conversation_activity_commands_run
        else -> when {
            name.startsWith("web_", ignoreCase = true) || name.startsWith("browser_", ignoreCase = true) -> if (running) R.string.conversation_activity_web_searching else R.string.conversation_activity_web_search
            running -> R.string.conversation_activity_other_running
            else -> 0
        }
    }
    return if (key == 0) name.replace('_', ' ').ifBlank { stringResource(R.string.conversation_tool) }
    else stringResource(key)
}

private fun mobileToolActivityIcon(toolName: String?, failed: Boolean = false): String {
    if (failed) return "!"
    val name = toolName.orEmpty().lowercase()
    return when {
        name in setOf("read_file", "list_files", "grep_files", "glob_files", "search_files", "get_latest_attachment") -> "⌕"
        name in setOf("write_file", "edit_file", "create_file", "delete_file", "copy_generated_media") -> "✎"
        name in setOf("run_command", "terminal_session", "shell", "exec") -> "⌘"
        name.startsWith("web_") || name.startsWith("browser_") -> "↗"
        else -> "⋯"
    }
}

/** A long build or test shows its own clock, so a quiet model never looks like a hung app.
 *  It counts from when the running row appeared, which is when the tool started. */
@Composable
private fun ToolClock() {
    val start = remember { System.currentTimeMillis() }
    var seconds by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (isActive) {
            seconds = ((System.currentTimeMillis() - start) / 1000).toInt()
            delay(1000)
        }
    }
    if (seconds >= 10) {
        Text(
            if (seconds < 60) "${seconds}s" else "${seconds / 60}m ${"%02d".format(seconds % 60)}s",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
        )
    }
}

/** Resolves the memory question keys MobileLessons uses against the app's strings. */
private fun memoryText(context: Context): (String) -> String = { key ->
    context.getString(
        when (key) {
            "memory.trust.prompt" -> R.string.memory_trust_prompt
            "memory.trust.yes" -> R.string.memory_trust_yes
            "memory.trust.no" -> R.string.memory_trust_no
            "memory.lesson.prompt" -> R.string.memory_lesson_prompt
            "memory.lesson.keep" -> R.string.memory_lesson_keep
            else -> R.string.memory_lesson_forget
        },
    )
}
