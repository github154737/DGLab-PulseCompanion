param([switch]$ConfirmPaidRequests)
$ErrorActionPreference = 'Stop'
if (-not $ConfirmPaidRequests) { throw 'This audit makes three small text-only API requests.' }
$auditRoot = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Security
$auditRaw = $null
try {
    $auditSource = [IO.File]::ReadAllText((Join-Path $auditRoot 'app/lib/api_model_provider.dart'))
    $auditBlock = [regex]::Match($auditSource, '(?s)static const _chatSystemPrompt =\s*(.*?);')
    if (-not $auditBlock.Success) { throw 'Chat prompt location changed; audit stopped.' }
    $auditPrompt = (@([regex]::Matches($auditBlock.Groups[1].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) -join '')
    if ($auditPrompt.Length -lt 100 -or $auditPrompt.Length -gt 3000) { throw 'Unexpected prompt structure.' }
    $auditModelSource = [IO.File]::ReadAllText((Join-Path $auditRoot 'app/lib/venice_transcription.dart'))
    $auditModel = [regex]::Match($auditModelSource, "const veniceTextModel = '([^']+)';").Groups[1].Value
    if ($auditModel -ne 'venice-uncensored-1-2') { throw 'Unexpected model; audit stopped.' }
    $auditVault = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIHaptics/private/venice/api-key.sealed'
    $auditRaw = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($auditVault), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $auditHeaders = @{Authorization=('Bearer ' + [Text.Encoding]::UTF8.GetString($auditRaw).Trim())}
    # These are synthetic, ordinary conversational fixtures, never user history.
    $auditQuestion = '今天有点累，想有人陪我聊两句。'
    $auditResults = @()
    foreach ($auditCase in @('fresh','prior_assistant_identity','fresh_style_request')) {
        $auditMessages = @(@{role='system';content=$auditPrompt})
        if ($auditCase -eq 'prior_assistant_identity') {
            $auditMessages += @{role='user';content='你好'}
            $auditMessages += @{role='assistant';content='我是一个处理文字信息的 AI 模型，可以帮助你学习和完成任务。'}
        }
        $auditText = $auditQuestion
        if ($auditCase -eq 'fresh_style_request') { $auditText += '请用温柔、简短的日常聊天口吻回应，不用介绍产品功能。' }
        $auditMessages += @{role='user';content=$auditText}
        $auditBody = @{model=$auditModel;temperature=0.8;max_tokens=600;stream=$false;messages=$auditMessages} | ConvertTo-Json -Depth 8 -Compress
        try {
            $auditResponse = Invoke-RestMethod -Uri 'https://api.venice.ai/api/v1/chat/completions' -Method Post -Headers $auditHeaders -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($auditBody)) -TimeoutSec 40
            $auditContent = [string]$auditResponse.choices[0].message.content
            $auditResults += [ordered]@{case=$auditCase;ok=$true;response_model=$auditResponse.model;provider_default_prompt=$auditResponse.venice_parameters.include_venice_system_prompt;provider_character=$auditResponse.venice_parameters.character_slug;finish_reason=$auditResponse.choices[0].finish_reason;reply=$auditContent;completion_tokens=$auditResponse.usage.completion_tokens}
        } catch {
            $auditResults += [ordered]@{case=$auditCase;ok=$false;error='Request failed; raw provider diagnostics suppressed.'}
        }
    }
    $auditReport = [ordered]@{time=(Get-Date -Format o);requested_model=$auditModel;prompt_source='current _chatSystemPrompt';temperature=0.8;max_tokens=600;provider_parameters_explicitly_set=$false;user_history_used=$false;results=$auditResults}
    $auditReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$auditRoot/reports/venice-chat-behavior-audit.json" -Encoding utf8
    $auditReport | ConvertTo-Json -Depth 8
} finally {
    if ($auditRaw) { [Array]::Clear($auditRaw,0,$auditRaw.Length) }
    $auditHeaders=$null
}
